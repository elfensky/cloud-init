# shellcheck shell=bash
# =============================================================================
# 61-rke2-config.sh — RKE2 node prompts + config.yaml + audit-policy.yaml
# =============================================================================
#
# All RKE2 prompts live here so the operator answers everything before any
# binaries land on disk. Writes:
#   /etc/rancher/rke2/config.yaml
#   /etc/rancher/rke2/audit-policy.yaml (servers, if audit logging enabled)
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_rke2_config() { [[ "$(state_get STEP_rke2_SELECTED)" == "yes" ]]; }

detect_rke2_config() {
    # Try to recover role and IP from an existing config.yaml.
    local cfg=/etc/rancher/rke2/config.yaml
    [[ -f "$cfg" ]] || return 0
    local ip
    ip="$(awk -F': ' '/^node-ip:/{gsub(/"/,"",$2); print $2; exit}' "$cfg")"
    [[ -n "$ip" ]] && state_set RKE2_NODE_IP "$ip"
    if grep -q "^server:" "$cfg"; then
        state_set RKE2_ROLE "server"
    elif grep -q "INSTALL_RKE2_TYPE=agent" /etc/default/rke2-* 2>/dev/null; then
        state_set RKE2_ROLE "worker"
    else
        state_set RKE2_ROLE "bootstrap"
    fi
}

configure_rke2_config() {
    # --- Node role ---
    local cur_idx=1
    case "$(state_get RKE2_ROLE)" in
        bootstrap) cur_idx=1 ;;
        server)    cur_idx=2 ;;
        worker)    cur_idx=3 ;;
    esac
    ask_choice "RKE2 node role" "$cur_idx" \
        "Bootstrap server|First server; initializes the cluster" \
        "Additional server|Joins existing cluster as control-plane + etcd" \
        "Worker|Agent node (workloads only)"
    case "$REPLY" in
        1) state_set RKE2_ROLE bootstrap ;;
        2) state_set RKE2_ROLE server ;;
        3) state_set RKE2_ROLE worker ;;
    esac

    # --- Node private IP ---
    while true; do
        ask_input "Node private IP (this node's address on the private network)" "$(state_get RKE2_NODE_IP "$(state_get NET_PRIVATE_IP)")"
        if validate_ip "$REPLY"; then
            state_set RKE2_NODE_IP "$REPLY"
            break
        fi
        err "Invalid IP: $REPLY"
    done

    # --- Cluster token ---
    local role
    role="$(state_get RKE2_ROLE)"
    if [[ "$role" == "bootstrap" ]]; then
        if [[ -z "$(state_get RKE2_TOKEN)" ]]; then
            local gen
            gen="$(generate_token)"
            info "Auto-generated cluster token: $gen"
            if ask_yesno "Use this token?" "y"; then
                state_set RKE2_TOKEN "$gen"
            else
                ask_input "Cluster token" ""
                state_set RKE2_TOKEN "$REPLY"
            fi
        fi
        warn "SAVE THIS TOKEN — you need it to join other nodes:"
        warn "  $(state_get RKE2_TOKEN | head -c 16)..."
    else
        ask_input "Cluster token (from bootstrap node)" "$(state_get RKE2_TOKEN)"
        state_set RKE2_TOKEN "$REPLY"

        # Server URL + reachability.
        ask_input "Server URL (e.g. https://10.0.0.8:6443)" "$(state_get RKE2_SERVER_URL)" '^https://'
        state_set RKE2_SERVER_URL "$REPLY"
        local hp host port
        hp="${REPLY#https://}"
        hp="${hp%%/*}"
        host="${hp%:*}"
        port="${hp#*:}"
        if ! test_tcp_connectivity "$host" "$port"; then
            err "Cannot reach ${host}:${port} — verify URL and firewall."
            exit 1
        fi
        log "API server reachable at ${host}:${port}"
    fi

    # --- TLS SANs + CNI + WireGuard (servers only) ---
    if [[ "$role" != "worker" ]]; then
        _collect_tls_sans
        _pick_cni
        _pick_wireguard
    fi

    # --- Advanced options (defaults are sensible) ---
    [[ -z "$(state_get RKE2_POD_CIDR)" ]]  && state_set RKE2_POD_CIDR  "10.42.0.0/16"
    [[ -z "$(state_get RKE2_SVC_CIDR)" ]]  && state_set RKE2_SVC_CIDR  "10.43.0.0/16"
    [[ -z "$(state_get RKE2_ETCD_METRICS)" ]]     && state_set RKE2_ETCD_METRICS "false"
    [[ -z "$(state_get RKE2_AUDIT_LOG)" ]]        && state_set RKE2_AUDIT_LOG    "yes"
    [[ -z "$(state_get RKE2_CHANNEL)" ]]           && state_set RKE2_CHANNEL      ""

    if ask_yesno "Configure advanced options (CIDRs, etcd metrics, audit, channel)?" "n"; then
        while true; do
            ask_input "Pod CIDR (RKE2 default shown; change only if it collides with your LAN)" "$(state_get RKE2_POD_CIDR)"
            validate_cidr "$REPLY" && { state_set RKE2_POD_CIDR "$REPLY"; break; }
            err "Invalid CIDR: $REPLY"
        done
        while true; do
            ask_input "Service CIDR (RKE2 default shown; change only if it collides with your LAN)" "$(state_get RKE2_SVC_CIDR)"
            validate_cidr "$REPLY" && { state_set RKE2_SVC_CIDR "$REPLY"; break; }
            err "Invalid CIDR: $REPLY"
        done
        if ask_yesno "Expose etcd metrics?" "n"; then
            state_set RKE2_ETCD_METRICS true
        else
            state_set RKE2_ETCD_METRICS false
        fi
        if ask_yesno "Enable API server audit logging?" "y"; then
            state_set RKE2_AUDIT_LOG yes
        else
            state_set RKE2_AUDIT_LOG no
        fi
        ask_input "RKE2 channel (stable, latest, v1.28...)" "$(state_get RKE2_CHANNEL stable)"
        local ch="$REPLY"
        [[ "$ch" == "stable" ]] && ch=""
        state_set RKE2_CHANNEL "$ch"
    fi

    # etcd quorum warning for joining servers.
    if [[ "$role" == "server" ]]; then
        echo ""
        warn "═══════════════════════════════════════════════════════════════"
        warn "  etcd QUORUM: Join servers ONE AT A TIME."
        warn "  Wait for this node to be Ready before joining the next."
        warn "═══════════════════════════════════════════════════════════════"
        echo ""
    fi
}

_collect_tls_sans() {
    local ip hostname san_list
    ip="$(state_get RKE2_NODE_IP)"
    hostname="$(state_get HOSTNAME_FQDN "$(hostname)")"
    san_list="${ip} ${hostname}"
    info "TLS SANs so far: ${san_list}"
    info "Add LB IPs, public IPs, or DNS names (one per line, blank to finish):"
    local san
    while true; do
        read -rp "Additional SAN: " san
        [[ -z "$san" ]] && break
        san_list="${san_list} ${san}"
    done
    state_set RKE2_TLS_SANS "$san_list"
}

_pick_cni() {
    local cur_idx=1
    case "$(state_get RKE2_CNI)" in
        calico) cur_idx=1 ;;
        cilium) cur_idx=2 ;;
        canal)  cur_idx=3 ;;
    esac
    local prompt="CNI plugin"
    [[ "$(state_get RKE2_ROLE)" == "server" ]] && prompt="CNI (must match bootstrap node)"
    ask_choice "$prompt" "$cur_idx" \
        "Calico|Mature; rich NetworkPolicy; VXLAN overlay" \
        "Cilium|eBPF dataplane; better observability" \
        "Canal|Flannel networking + Calico policies"
    case "$REPLY" in
        1) state_set RKE2_CNI calico ;;
        2) state_set RKE2_CNI cilium ;;
        3) state_set RKE2_CNI canal ;;
    esac
}

_pick_wireguard() {
    echo ""
    case "$(state_get RKE2_CNI)" in
        calico) info "Calico WireGuard: enabled via kubectl patch AFTER all nodes join." ;;
        cilium) info "Cilium WireGuard: configured pre-install via HelmChartConfig." ;;
        canal)  warn "Canal WireGuard: less mature than Calico/Cilium." ;;
    esac
    if ask_yesno "Enable WireGuard pod-to-pod encryption?" "n"; then
        state_set RKE2_WIREGUARD yes
    else
        state_set RKE2_WIREGUARD no
    fi
}

check_rke2_config() {
    [[ -f /etc/rancher/rke2/config.yaml ]] \
        && grep -q "node-ip: \"$(state_get RKE2_NODE_IP)\"" /etc/rancher/rke2/config.yaml
}

run_rke2_config() {
    local role token node_ip server_url cni pod_cidr svc_cidr etcd_metrics audit
    role="$(state_get RKE2_ROLE)"
    token="$(state_get RKE2_TOKEN)"
    node_ip="$(state_get RKE2_NODE_IP)"
    server_url="$(state_get RKE2_SERVER_URL)"
    cni="$(state_get RKE2_CNI)"
    pod_cidr="$(state_get RKE2_POD_CIDR)"
    svc_cidr="$(state_get RKE2_SVC_CIDR)"
    etcd_metrics="$(state_get RKE2_ETCD_METRICS false)"
    audit="$(state_get RKE2_AUDIT_LOG yes)"

    mkdir -p /etc/rancher/rke2
    chmod 700 /etc/rancher/rke2

    {
        if [[ "$role" == "worker" ]]; then
            cat <<CFG
token: "${token}"
server: "${server_url}"
node-ip: "${node_ip}"
profile: "cis"
protect-kernel-defaults: true
kubelet-arg:
  - "node-ip=${node_ip}"
  - "streaming-connection-idle-timeout=5m"
  - "make-iptables-util-chains=true"
  - "rotate-certificates=true"
  - "container-log-max-size=50Mi"
  - "container-log-max-files=5"
CFG
        else
            echo "token: \"${token}\""
            [[ "$role" == "server" ]] && echo "server: \"${server_url}\""
            cat <<CFG
node-ip: "${node_ip}"
bind-address: "${node_ip}"
advertise-address: "${node_ip}"
node-taint:
  - "node-role.kubernetes.io/control-plane:NoSchedule"
CFG
            local san_list sans
            san_list="$(state_get RKE2_TLS_SANS)"
            if [[ -n "$san_list" ]]; then
                echo "tls-san:"
                read -ra sans <<< "$san_list"
                for s in "${sans[@]}"; do
                    echo "  - \"${s}\""
                done
            fi
            echo "cni: ${cni}"
            echo "secrets-encryption: true"
            echo 'profile: "cis"'
            echo "protect-kernel-defaults: true"
            echo ""
            cat <<CFG
kubelet-arg:
  - "node-ip=${node_ip}"
  - "streaming-connection-idle-timeout=5m"
  - "make-iptables-util-chains=true"
  - "rotate-certificates=true"
  - "container-log-max-size=50Mi"
  - "container-log-max-files=5"
etcd-expose-metrics: ${etcd_metrics}
CFG
            cat <<'CFG'
kube-apiserver-arg:
  - "tls-min-version=VersionTLS12"
  - "tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305"
CFG
            if [[ "$audit" == "yes" ]]; then
                cat <<'CFG'
  - "audit-log-path=/var/lib/rancher/rke2/server/logs/audit.log"
  - "audit-log-maxage=30"
  - "audit-log-maxbackup=10"
  - "audit-log-maxsize=100"
  - "audit-policy-file=/etc/rancher/rke2/audit-policy.yaml"
CFG
            fi
            cat <<'CFG'
kube-controller-manager-arg:
  - "tls-min-version=VersionTLS12"
kube-scheduler-arg:
  - "tls-min-version=VersionTLS12"
CFG
            [[ "$pod_cidr" != "10.42.0.0/16" ]] && echo "cluster-cidr: \"${pod_cidr}\""
            [[ "$svc_cidr" != "10.43.0.0/16" ]] && echo "service-cidr: \"${svc_cidr}\""
        fi
    } > /etc/rancher/rke2/config.yaml
    chmod 600 /etc/rancher/rke2/config.yaml

    # Audit policy for servers with audit-log enabled.
    if [[ "$role" != "worker" && "$audit" == "yes" ]]; then
        cat > /etc/rancher/rke2/audit-policy.yaml <<'AUDIT'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: None
    nonResourceURLs: ["/healthz*", "/livez*", "/readyz*", "/version"]
  - level: None
    resources:
      - group: ""
        resources: ["events"]
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
  - level: Metadata
    resources:
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]
      - group: "authorization.k8s.io"
        resources: ["subjectaccessreviews"]
  - level: Metadata
    omitStages: ["RequestReceived"]
AUDIT
        chmod 600 /etc/rancher/rke2/audit-policy.yaml
        log "Audit policy written"
    fi

    # Host-level auditd rules for K8s (used to live in 59-audit.sh; folded
    # here because these rules are only meaningful when RKE2 is configured).
    cat > /etc/audit/rules.d/rke2.rules <<'EOF'
# RKE2 binaries — detect unauthorized execution or replacement.
-w /usr/local/bin/rke2 -p x -k rke2
-w /var/lib/rancher/rke2/bin/ -p x -k rke2-bins

# RKE2/Rancher config and data.
-w /etc/rancher/ -p wa -k rancher-config
-w /var/lib/rancher/ -p wa -k rancher-data

# Identity files.
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity

# Sudoers.
-w /etc/sudoers -p wa -k sudo-changes
-w /etc/sudoers.d/ -p wa -k sudo-changes

# Home directories (authorized_keys changes).
-w /home/ -p wa -k home-changes

# Cron (persistence via scheduled tasks).
-w /etc/crontab -p wa -k cron
-w /etc/cron.d/ -p wa -k cron
EOF

    systemctl enable auditd --now 2>/dev/null || true
    augenrules --load 2>/dev/null || systemctl restart auditd 2>/dev/null || true
    log "Audit rules installed (RKE2, identity, sudo, cron)"

    log "config.yaml written to /etc/rancher/rke2/config.yaml"
}

verify_rke2_config() {
    [[ -f /etc/rancher/rke2/config.yaml ]] \
        && grep -q "node-ip: \"$(state_get RKE2_NODE_IP)\"" /etc/rancher/rke2/config.yaml \
        && [[ -f /etc/audit/rules.d/rke2.rules ]]
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_rke2_config || exit 0
    detect_rke2_config
    configure_rke2_config
    run_rke2_config
    verify_rke2_config || { err "RKE2 config verification failed"; exit 1; }
fi
