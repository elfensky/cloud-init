#!/usr/bin/env bash
# =============================================================================
# init.2.rke2.sh — RKE2 Installation & Configuration
# =============================================================================
#
# Purpose
# -------
# Interactively configures and installs RKE2 (Rancher Kubernetes Engine 2)
# on a single node. Run once per node after init.1.vps.sh has hardened the OS.
#
# Usage
# -----
#   sudo ./init.2.rke2.sh
#
# Preflight
# ---------
# Before prompting, the script:
#   - Checks net.ipv4.ip_forward — confirms init.1.vps.sh ran in K8s mode
#   - Detects the private network interface and IP to pre-populate defaults
#   - Warns if RKE2 is already running (reconfiguring a live node is risky)
#
# Interactive Steps
# -----------------
#   1. Node role        — bootstrap, additional server, or worker
#   2. Node IP          — private IP for intra-cluster communication
#   3. Hostname         — set via hostnamectl
#   4. Cluster token    — shared secret authenticating nodes to each other
#   5. Server URL       — API server endpoint (joining nodes only)
#   6. TLS SANs         — extra IPs/domains for the API server certificate
#   7. CNI plugin       — Calico, Cilium, or Canal
#   8. WireGuard        — optional pod-to-pod encryption
#   9. Advanced options — CIDRs, etcd metrics, audit logging, release channel
#  10. Confirmation     — summary review before execution
#
# Node Join Order
# ---------------
# Servers must be joined one at a time and each must reach Ready before the
# next joins — etcd uses Raft consensus and simultaneous joins can break
# quorum. Workers have no such constraint and may join in parallel.
#
# Output
# ------
# - /etc/rancher/rke2/config.yaml               — RKE2 node configuration
# - /var/lib/rancher/rke2/server/manifests/*.yaml — HelmChartConfig manifests
#   for WireGuard (bootstrap node only)
#
# Next
# ----
# After all nodes have joined and are Ready, run init.3.pods.sh on a server
# node to deploy the platform stack (ingress, cert-manager, monitoring, etc.).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# =============================================================================
# Preflight
# =============================================================================
require_root
require_ubuntu
ensure_tmux "$@"

banner "RKE2 Installation — init.rke2.sh" "Ubuntu ${UBUNTU_VERSION}"

# ip_forward must be enabled for pod networking (VXLAN/eBPF overlays) to work.
# init.1.vps.sh sets this when the "Kubernetes node" purpose is selected.
# Without it, pods on different nodes cannot communicate.
if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ]]; then
    err "net.ipv4.ip_forward is not enabled."
    err "Run init.vps.sh with 'Kubernetes node' purpose first."
    exit 1
fi

# Detect the private network interface (e.g., enp7s0 on Hetzner) and extract
# its IPv4 address. These values pre-populate the interactive prompts so the
# operator does not have to look them up manually.
if detect_private_iface; then
    info "Private interface: ${PRIVATE_IFACE}"
    get_private_ip "$PRIVATE_IFACE" && info "Private IP: ${PRIVATE_IP}" || true
else
    warn "No private interface detected."
fi

# Reconfiguring a node while RKE2 is running can cause etcd split-brain or
# API server certificate mismatches. Warn loudly and require explicit opt-in.
if systemctl is-active --quiet rke2-server 2>/dev/null || systemctl is-active --quiet rke2-agent 2>/dev/null; then
    warn "RKE2 is already running on this node!"
    if ! ask_yesno "Continue anyway? (will reconfigure)" "n"; then
        exit 0
    fi
fi

# =============================================================================
# Interactive Configuration
# =============================================================================

# --- Step 1: Node role ---
# Bootstrap = first server; initializes a single-node etcd cluster.
# Additional server = joins the existing etcd cluster (control-plane + etcd).
# Worker = runs workloads only; no etcd or API server components.
ask_choice "Node role?" 1 \
    "Bootstrap server|First server node, initializes the cluster" \
    "Additional server|Joins existing cluster as control-plane + etcd" \
    "Worker|Joins as agent node (ingress + workloads)"
NODE_ROLE=$REPLY  # 1=bootstrap, 2=server, 3=worker

# --- Step 2: Node private IP ---
# Inter-node traffic (etcd, kubelet, CNI overlays) should stay on the private
# network to avoid exposing cluster traffic on the public interface.
DEFAULT_IP="${PRIVATE_IP:-}"
ask_input "Node private IP" "$DEFAULT_IP"
NODE_IP="$REPLY"
if ! validate_ip "$NODE_IP"; then
    err "Invalid IP: ${NODE_IP}"
    exit 1
fi

# --- Step 3: Hostname ---
ask_input "Hostname" "$(hostname)"
NODE_HOSTNAME="$REPLY"

# --- Step 4: Cluster token ---
# A 256-bit hex token is the shared secret that authenticates every node to the
# cluster. All nodes (servers and workers) must use the same token.
if [[ "$NODE_ROLE" -eq 1 ]]; then
    # Bootstrap convenience: auto-generate a cryptographically random token.
    # The operator can override if they want a pre-determined value.
    GENERATED_TOKEN="$(generate_token)"
    info "Auto-generated cluster token: ${GENERATED_TOKEN}"
    if ask_yesno "Use this token?" "y"; then
        CLUSTER_TOKEN="$GENERATED_TOKEN"
    else
        ask_input "Cluster token" ""
        CLUSTER_TOKEN="$REPLY"
    fi

    echo ""
    warn "═══════════════════════════════════════════════════════════════"
    warn "  SAVE THIS TOKEN — you need it to join other nodes:"
    warn "  ${CLUSTER_TOKEN:0:16}..."
    warn "═══════════════════════════════════════════════════════════════"
    echo ""
else
    # Joining nodes must provide the token that the bootstrap node generated.
    ask_input "Cluster token (from bootstrap node)" ""
    CLUSTER_TOKEN="$REPLY"
fi

# --- Step 5: Server URL (joining nodes only) ---
# The URL must use https:// and port 6443 (Kubernetes API server default).
# Bootstrap nodes do not need this — they ARE the initial server.
SERVER_URL=""
if [[ "$NODE_ROLE" -ne 1 ]]; then
    ask_input "Server URL (e.g. https://10.0.0.8:6443)" "" '^https://'
    SERVER_URL="$REPLY"

    # Verify API server reachability before proceeding with installation.
    # A bad URL causes a silent 300s timeout during systemctl start.
    _hostport="${SERVER_URL#https://}"
    _hostport="${_hostport%%/*}"
    _srv_host="${_hostport%:*}"
    _srv_port="${_hostport#*:}"
    if ! test_tcp_connectivity "$_srv_host" "$_srv_port"; then
        err "Cannot reach ${_srv_host}:${_srv_port} — verify URL and firewall."
        exit 1
    fi
    log "API server reachable at ${_srv_host}:${_srv_port}"
fi

# --- Step 6: TLS SANs (server roles only) ---
# The API server's TLS certificate must include every IP address and domain
# name that clients use to reach it. Missing SANs cause x509 certificate
# errors when kubectl or other tools connect. The node IP and hostname are
# added automatically; the operator adds any load-balancer IPs or DNS names.
TLS_SANS=()
if [[ "$NODE_ROLE" -le 2 ]]; then
    TLS_SANS+=("$NODE_IP" "$NODE_HOSTNAME")
    echo ""
    info "TLS SANs so far: ${TLS_SANS[*]}"
    info "Add LB IPs, public IPs, or domain names (one per line)."
    info "Press Enter on empty line when done."
    while true; do
        read -rp "Additional SAN: " san
        [[ -z "$san" ]] && break
        TLS_SANS+=("$san")
    done
fi

# --- Step 7: CNI selection ---
# Calico  — mature, rich NetworkPolicy support, VXLAN overlay.
# Cilium  — eBPF-based dataplane, better observability, newer.
# Canal   — Flannel for networking + Calico for policies (legacy combo).
CNI="calico"
WIREGUARD="n"

if [[ "$NODE_ROLE" -eq 1 ]]; then
    # Bootstrap node defines the CNI for the entire cluster.
    ask_choice "CNI plugin?" 1 \
        "Calico|Mature, policy-rich, VXLAN overlay" \
        "Cilium|eBPF-based, modern observability" \
        "Canal|Flannel networking + Calico policies"
    case $REPLY in
        1) CNI="calico" ;;
        2) CNI="cilium" ;;
        3) CNI="canal" ;;
    esac
elif [[ "$NODE_ROLE" -eq 2 ]]; then
    # Joining servers must use the same CNI the bootstrap node selected.
    echo ""
    warn "CNI MUST match the bootstrap node. A mismatch causes silent join failures."
    ask_choice "CNI (must match bootstrap node)?" 1 \
        "Calico|VXLAN overlay" \
        "Cilium|eBPF-based" \
        "Canal|Flannel + Calico"
    case $REPLY in
        1) CNI="calico" ;;
        2) CNI="cilium" ;;
        3) CNI="canal" ;;
    esac
fi

# --- Step 8: WireGuard (server roles only, not workers) ---
# WireGuard encrypts pod-to-pod traffic at the CNI level. The enablement
# mechanism differs per CNI:
#   Calico  — enabled post-install via kubectl patch on felixconfiguration
#   Cilium  — configured pre-install via HelmChartConfig manifest
#   Canal   — configured pre-install via HelmChartConfig (less mature/stable)
if [[ "$NODE_ROLE" -le 2 ]]; then
    echo ""
    case "$CNI" in
        calico)
            info "Calico WireGuard: encrypts pod-to-pod traffic."
            info "Enabled via kubectl patch AFTER all nodes join."
            ;;
        cilium)
            info "Cilium WireGuard: transparent encryption via eBPF."
            info "Configured before RKE2 start via HelmChartConfig."
            ;;
        canal)
            warn "Canal WireGuard: less mature than Calico/Cilium."
            warn "May have stability issues in production."
            ;;
    esac

    if ask_yesno "Enable WireGuard encryption?" "n"; then
        WIREGUARD="y"
    fi
fi

# --- Step 9: Advanced options ---
# Pod CIDR  10.42.0.0/16 and Service CIDR 10.43.0.0/16 are RKE2 defaults.
# Only change them if they conflict with existing network ranges on the host
# or VPC (e.g., the private network already uses 10.42.x.x).
POD_CIDR="10.42.0.0/16"
SVC_CIDR="10.43.0.0/16"
ETCD_METRICS="false"
AUDIT_LOG="y"
RKE2_CHANNEL=""

if ask_yesno "Configure advanced options?" "n"; then
    ask_input "Pod CIDR" "$POD_CIDR"
    POD_CIDR="$REPLY"
    if ! validate_cidr "$POD_CIDR"; then
        err "Invalid CIDR: ${POD_CIDR}"
        exit 1
    fi

    ask_input "Service CIDR" "$SVC_CIDR"
    SVC_CIDR="$REPLY"
    if ! validate_cidr "$SVC_CIDR"; then
        err "Invalid CIDR: ${SVC_CIDR}"
        exit 1
    fi

    # etcd metrics expose a /metrics endpoint for Prometheus scraping.
    # Disabled by default: leaks cluster topology without authentication.
    # Enable when deploying a monitoring stack with mTLS scraping.
    if ask_yesno "Expose etcd metrics?" "n"; then
        ETCD_METRICS="true"
    fi

    # API server audit logging writes a request audit trail for security
    # compliance (who did what and when).
    if ! ask_yesno "Enable API server audit logging?" "y"; then
        AUDIT_LOG="n"
    fi

    read -rp "RKE2 channel (e.g. stable, latest, v1.28) [default]: " RKE2_CHANNEL
fi

# --- Step 10: Confirmation ---
ROLE_LABEL="Bootstrap server"
[[ "$NODE_ROLE" -eq 2 ]] && ROLE_LABEL="Additional server"
[[ "$NODE_ROLE" -eq 3 ]] && ROLE_LABEL="Worker"

summary_args=(
    "Role|${ROLE_LABEL}"
    "Node IP|${NODE_IP}"
    "Hostname|${NODE_HOSTNAME}"
    "Token|${CLUSTER_TOKEN:0:16}..."
)
[[ -n "$SERVER_URL" ]] && summary_args+=("Server URL|${SERVER_URL}")
[[ ${#TLS_SANS[@]} -gt 0 ]] && summary_args+=("TLS SANs|${TLS_SANS[*]}")
[[ "$NODE_ROLE" -le 2 ]] && summary_args+=("CNI|${CNI}")
[[ "$WIREGUARD" == "y" ]] && summary_args+=("WireGuard|enabled")
summary_args+=(
    "Pod CIDR|${POD_CIDR}"
    "Service CIDR|${SVC_CIDR}"
)

print_summary "RKE2 Configuration" "${summary_args[@]}"

# etcd quorum warning: Raft consensus requires a strict majority of members
# to agree. Joining two servers simultaneously can cause split-brain where
# neither partition has quorum, leaving the cluster unrecoverable.
if [[ "$NODE_ROLE" -eq 2 ]]; then
    echo ""
    warn "═══════════════════════════════════════════════════════════════"
    warn "  etcd QUORUM: Join servers ONE AT A TIME."
    warn "  Wait for this node to be Ready before joining the next."
    warn "═══════════════════════════════════════════════════════════════"
    echo ""
fi

if ! ask_yesno "Proceed?" "n"; then
    info "Aborted."
    exit 0
fi

# =============================================================================
# Execution
# =============================================================================

# --- 1. Set hostname ---
separator "Hostname"
hostnamectl set-hostname "$NODE_HOSTNAME"
log "Hostname: ${NODE_HOSTNAME}"

# --- 2. Write config.yaml ---
# The config file is the primary input to the RKE2 server/agent process.
# It is written idempotently via cat > (overwrite, never append).
separator "RKE2 Config"
mkdir -p /etc/rancher/rke2
chmod 700 /etc/rancher/rke2

{
    if [[ "$NODE_ROLE" -eq 3 ]]; then
        # Worker config is minimal — it only needs credentials to join the
        # cluster and a node-ip to register with.
        cat <<CFGEOF
token: "${CLUSTER_TOKEN}"
server: "${SERVER_URL}"
node-ip: "${NODE_IP}"
profile: "cis"
protect-kernel-defaults: true
kubelet-arg:
  - "node-ip=${NODE_IP}"
  - "streaming-connection-idle-timeout=5m"
  - "make-iptables-util-chains=true"
  - "rotate-certificates=true"
  - "container-log-max-size=50Mi"
  - "container-log-max-files=5"
CFGEOF
    else
        # Server config: bind-address and advertise-address are pinned to the
        # private IP to prevent the API server from listening on the public
        # interface, which would expose the Kubernetes API to the internet.
        #
        # Token is quoted in YAML because tokens may contain special characters
        # that would otherwise break YAML parsing.
        echo "token: \"${CLUSTER_TOKEN}\""

        # Only joining servers need a server URL; the bootstrap node is the
        # initial server and has no existing cluster to contact.
        if [[ "$NODE_ROLE" -eq 2 ]]; then
            echo "server: \"${SERVER_URL}\""
        fi

        cat <<CFGEOF
node-ip: "${NODE_IP}"
bind-address: "${NODE_IP}"
advertise-address: "${NODE_IP}"
node-taint:
  - "node-role.kubernetes.io/control-plane:NoSchedule"
CFGEOF

        # TLS SANs are added to the API server's self-signed certificate.
        # Without them, clients connecting via unlisted IPs/domains get
        # "x509: certificate is valid for X, not Y" errors.
        if [[ ${#TLS_SANS[@]} -gt 0 ]]; then
            echo "tls-san:"
            for san in "${TLS_SANS[@]}"; do
                echo "  - \"${san}\""
            done
        fi

        echo "cni: ${CNI}"
        # CIS hardening: encrypts secrets at rest in etcd, enforces Pod Security
        # Standards, and prevents kubelet from silently modifying kernel parameters.
        echo "secrets-encryption: true"
        echo 'profile: "cis"'
        echo "protect-kernel-defaults: true"
        echo ""

        # kubelet-arg node-ip forces kubelet to register with the private IP.
        # Without this, kubelet may pick the public IP, causing inter-node
        # traffic to route over the public internet instead of the private LAN.
        cat <<CFGEOF
kubelet-arg:
  - "node-ip=${NODE_IP}"
  - "streaming-connection-idle-timeout=5m"
  - "make-iptables-util-chains=true"
  - "rotate-certificates=true"
  - "container-log-max-size=50Mi"
  - "container-log-max-files=5"
etcd-expose-metrics: ${ETCD_METRICS}
CFGEOF

        # TLS 1.2 floor and AEAD-only cipher suites for all control-plane components.
        # Explicit config satisfies CIS 1.2.25 and prevents downgrades across updates.
        cat <<'CFGEOF'
kube-apiserver-arg:
  - "tls-min-version=VersionTLS12"
  - "tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305"
CFGEOF

        # Audit logging records API server requests (who, what, when) for
        # security compliance. Logs rotate at 100MB, keeping 10 backups
        # for up to 30 days.
        if [[ "$AUDIT_LOG" == "y" ]]; then
            cat <<'CFGEOF'
  - "audit-log-path=/var/lib/rancher/rke2/server/logs/audit.log"
  - "audit-log-maxage=30"
  - "audit-log-maxbackup=10"
  - "audit-log-maxsize=100"
  - "audit-policy-file=/etc/rancher/rke2/audit-policy.yaml"
CFGEOF
        fi

        cat <<'CFGEOF'
kube-controller-manager-arg:
  - "tls-min-version=VersionTLS12"
kube-scheduler-arg:
  - "tls-min-version=VersionTLS12"
CFGEOF

        # Custom CIDRs are only written when they differ from RKE2 defaults.
        # This keeps config.yaml clean and makes it obvious when non-standard
        # ranges are in use.
        if [[ "$POD_CIDR" != "10.42.0.0/16" ]]; then
            echo "cluster-cidr: \"${POD_CIDR}\""
        fi
        if [[ "$SVC_CIDR" != "10.43.0.0/16" ]]; then
            echo "service-cidr: \"${SVC_CIDR}\""
        fi
    fi
} > /etc/rancher/rke2/config.yaml
chmod 600 /etc/rancher/rke2/config.yaml

log "config.yaml written to /etc/rancher/rke2/config.yaml"
echo ""
info "Contents:"
cat /etc/rancher/rke2/config.yaml
echo ""

# --- Audit policy ---
# The audit policy defines which API requests are logged and at what detail
# level. Without it, audit-log-path produces an empty file (kube-apiserver
# default is to log nothing). This policy logs all requests at Metadata level
# (who/what/when) while skipping high-volume health probes and events.
if [[ "$AUDIT_LOG" == "y" && "$NODE_ROLE" -le 2 ]]; then
    cat > /etc/rancher/rke2/audit-policy.yaml <<'AUDITEOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Health/readiness probes generate thousands of entries per hour — skip them.
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/livez*"
      - "/readyz*"
      - "/version"
  # Event objects are high-volume and rarely security-relevant.
  - level: None
    resources:
      - group: ""
        resources: ["events"]
  # Secret and ConfigMap access is security-sensitive — log at Metadata level.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
  # Authentication and authorization decisions.
  - level: Metadata
    resources:
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]
      - group: "authorization.k8s.io"
        resources: ["subjectaccessreviews"]
  # Everything else: log who/what/when (not request/response bodies).
  - level: Metadata
    omitStages:
      - RequestReceived
AUDITEOF
    chmod 600 /etc/rancher/rke2/audit-policy.yaml
    log "Audit policy written to /etc/rancher/rke2/audit-policy.yaml"
fi

# --- 3. HelmChartConfig for WireGuard (bootstrap only) ---
# HelmChartConfig is an RKE2-specific CRD. YAML files placed in
# /var/lib/rancher/rke2/server/manifests/ are automatically applied when the
# server first boots. Only the bootstrap node writes these — additional servers
# read the resulting cluster state from etcd.
if [[ "$WIREGUARD" == "y" && "$NODE_ROLE" -eq 1 ]]; then
    MANIFESTS_DIR="/var/lib/rancher/rke2/server/manifests"
    mkdir -p "$MANIFESTS_DIR"
    chmod 700 "$MANIFESTS_DIR"

    case "$CNI" in
        cilium)
            # Cilium WireGuard: encryption.enabled + type=wireguard enables
            # transparent pod-to-pod encryption at the eBPF dataplane level.
            separator "Cilium WireGuard HelmChartConfig"
            cat > "${MANIFESTS_DIR}/rke2-cilium-config.yaml" <<'HELMEOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
  valuesContent: |-
    encryption:
      enabled: true
      type: wireguard
HELMEOF
            log "Cilium WireGuard HelmChartConfig written"
            ;;
        canal)
            # Canal WireGuard: swaps the default VXLAN tunnel backend for
            # WireGuard, encrypting all Flannel-managed pod traffic.
            separator "Canal WireGuard HelmChartConfig"
            cat > "${MANIFESTS_DIR}/rke2-canal-config.yaml" <<'HELMEOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-canal
  namespace: kube-system
spec:
  valuesContent: |-
    flannel:
      backend: "wireguard"
HELMEOF
            log "Canal WireGuard HelmChartConfig written"
            warn "Canal WireGuard is less mature — monitor for stability issues."
            ;;
        calico)
            # Calico WireGuard requires no pre-install manifest. It is enabled
            # post-install via a kubectl patch on the felixconfiguration CRD,
            # which must wait until ALL nodes have joined because the setting
            # is cluster-wide.
            info "Calico WireGuard will be enabled after all nodes join (see post-install)."
            ;;
    esac
fi

# --- 4. Install RKE2 ---
# curl flags: -s silent, -f fail on HTTP error, -L follow redirects.
# The official installer script detects architecture and downloads the
# appropriate RKE2 binary and systemd unit files.
separator "RKE2 Installation"

INSTALL_ARGS=()
# Workers need the agent binary only — no API server, etcd, or scheduler.
if [[ "$NODE_ROLE" -eq 3 ]]; then
    INSTALL_ARGS+=("INSTALL_RKE2_TYPE=agent")
fi
# Pin to a specific release channel (e.g., stable, latest, v1.28) if requested.
if [[ -n "$RKE2_CHANNEL" ]]; then
    INSTALL_ARGS+=("INSTALL_RKE2_CHANNEL=${RKE2_CHANNEL}")
fi

info "Installing RKE2..."
# Download installer to temp file instead of piping to shell (NIST SI-7).
# Prevents MITM execution and creates an audit trail via sha256 checksum.
# The installer itself verifies the RKE2 binary it downloads.
INSTALLER_TMP="$(mktemp)"
trap 'rm -f "$INSTALLER_TMP"' EXIT
curl --proto '=https' --tlsv1.2 -sfL https://get.rke2.io -o "$INSTALLER_TMP"
log "Installer sha256: $(sha256sum "$INSTALLER_TMP" | cut -d' ' -f1)"

if [[ ${#INSTALL_ARGS[@]} -gt 0 ]]; then
    env "${INSTALL_ARGS[@]}" bash "$INSTALLER_TMP"
else
    bash "$INSTALLER_TMP"
fi
log "RKE2 installed"
info "Installed: $(/usr/local/bin/rke2 --version 2>/dev/null | head -1 || echo 'version unknown')"

# --- 5. Enable + start ---
separator "Starting RKE2"

if [[ "$NODE_ROLE" -eq 3 ]]; then
    RKE2_SERVICE="rke2-agent"
else
    RKE2_SERVICE="rke2-server"
fi

systemctl enable "$RKE2_SERVICE"
info "Starting ${RKE2_SERVICE}... (this may take several minutes)"

if ! timeout 300 systemctl start "$RKE2_SERVICE"; then
    err "${RKE2_SERVICE} failed to start within 300s"
    err "Check: journalctl -u ${RKE2_SERVICE} --no-pager -n 50"
    exit 1
fi

log "${RKE2_SERVICE} started"

# Server nodes need extra settle time after systemd reports the unit as active.
# The API server, etcd, and scheduler components are still initializing
# internal state even though the process itself is running.
if [[ "$NODE_ROLE" -le 2 ]]; then
    info "Waiting 30s for API server to settle..."
    sleep 30
fi

# --- 7. Post-install ---
separator "Post-Install"

if [[ "$NODE_ROLE" -eq 1 ]]; then
    # Set up kubectl for all users via profile.d (idempotent overwrite)
    cat > /etc/profile.d/rke2.sh <<'PROFILEEOF'
export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
PROFILEEOF

    export PATH=$PATH:/var/lib/rancher/rke2/bin
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    chmod 600 /etc/rancher/rke2/rke2.yaml

    info "Verifying cluster..."
    sleep 10
    kubectl get nodes 2>/dev/null || warn "kubectl not ready yet — check again in a minute."
    echo ""

    # Calico WireGuard is enabled via a cluster-wide felixconfiguration patch.
    # It must wait until ALL nodes have joined because the setting applies to
    # every node simultaneously — applying it early causes connection failures
    # on nodes that haven't installed WireGuard kernel modules yet.
    if [[ "$WIREGUARD" == "y" && "$CNI" == "calico" ]]; then
        # Write convenience script so the operator doesn't need to remember
        # the kubectl patch command. chmod 700 = root-only execution.
        cat > /usr/local/bin/rke2-enable-wireguard <<'WGEOF'
#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin
echo "Enabling Calico WireGuard encryption..."
kubectl patch felixconfiguration default --type=merge \
  -p '{"spec":{"wireguardEnabled":true}}'
echo "Done. Verify: kubectl get felixconfiguration default -o jsonpath='{.spec.wireguardEnabled}'"
WGEOF
        chmod 700 /usr/local/bin/rke2-enable-wireguard

        echo ""
        warn "═══════════════════════════════════════════════════════════════"
        warn "  CALICO WIREGUARD — AFTER all nodes have joined, run:"
        warn ""
        warn "    rke2-enable-wireguard"
        warn ""
        warn "  Applying before all nodes join causes connection failures"
        warn "  on nodes without WireGuard kernel modules."
        warn "═══════════════════════════════════════════════════════════════"
        echo ""
    fi

    echo ""
    log "Bootstrap complete!"
    echo ""
    info "Next steps:"
    info "  1. Join additional servers ONE AT A TIME with init.rke2.sh"
    info "     Wait for each to show Ready: kubectl get nodes -w"
    info "  2. Then join workers (can be done in parallel)"
    info "  3. Label workers:"
    info "     kubectl label node <name> node-role.kubernetes.io/worker=worker"
    info "  4. Run init.pods.sh on a server node to deploy the platform stack"

elif [[ "$NODE_ROLE" -eq 2 ]]; then
    log "Server node joined!"
    echo ""
    info "On the bootstrap node, verify:"
    info "  kubectl get nodes"
    info "  Wait for this node to show Ready before joining the next."

else
    log "Worker node joined!"
    echo ""
    info "On a server node, verify:"
    info "  kubectl get nodes"
    info "  Label this worker:"
    info "  kubectl label node ${NODE_HOSTNAME} node-role.kubernetes.io/worker=worker"
fi
