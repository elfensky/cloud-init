#!/usr/bin/env bash
# =============================================================================
# init.3.pods.sh — Platform Stack Deployment via Helm
# =============================================================================
#
# Purpose
# -------
#   Deploys the platform stack (Helm charts + infrastructure services) onto an
#   RKE2 Kubernetes cluster. Run once on a SERVER node after all nodes have
#   joined the cluster.
#
# Usage
# -----
#   sudo ./init.3.pods.sh
#
# Preflight
# ---------
#   - Verifies kubectl is available (RKE2 server installed on this node)
#   - Tests cluster connectivity (API server reachable, valid kubeconfig)
#   - Warns about NotReady nodes (deploying to a partial cluster can leave
#     pods stuck in Pending due to insufficient resources)
#
# Component Selection (interactive multi-select with dependency auto-resolution)
#   - Helm              — package manager (required by all Helm charts)
#   - local-path-provisioner — node-local storage class for PVCs
#   - ingress-nginx     — ingress controller with Proxy Protocol support
#   - cert-manager      — automated Let's Encrypt TLS certificates
#   - Monitoring        — Prometheus + Grafana + Alertmanager
#   - Logging           — Loki + Promtail
#   - CrowdSec          — L7 WAF + bot protection for ingress (off by default)
#   - Rancher           — Kubernetes management UI (off by default)
#
# Dependency Rules (auto-resolved if a downstream component is selected)
#   - Rancher       -> cert-manager (TLS) + ingress-nginx (HTTP routing)
#   - CrowdSec      -> ingress-nginx (bounces at the ingress level)
#   - Monitoring    -> local-path-provisioner (PVCs for data persistence)
#   - Logging       -> local-path-provisioner (PVCs for data persistence)
#   - Any Helm chart -> Helm
#
# CRITICAL — Proxy Protocol ordering:
#   Install ingress-nginx FIRST (it expects Proxy Protocol from the first
#   request). THEN enable Proxy Protocol on the load balancer for ports 80/443.
#   If the LB sends plain HTTP while nginx expects PP, clients get 400 errors.
#   If nginx expects plain HTTP while LB sends PP, nginx sees garbage bytes.
#
# Output
# ------
#   /root/platform-credentials.txt (mode 600) — all generated passwords
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

TMPDIR_PODS=$(mktemp -d)
chmod 700 "$TMPDIR_PODS"
trap 'rm -rf "$TMPDIR_PODS"' EXIT

LOCAL_PATH_VERSION="v0.0.30"
LOCAL_PATH_SHA256="fe682186b00400fe7e2b72bae16f63e47a56a6dcc677938c6642139ef670045e"

# Helm chart versions — pin to avoid breaking changes from upstream releases.
# Update these deliberately after testing, not accidentally by re-running.
HELM_VERSION="v3.17.1"
INGRESS_NGINX_VERSION="4.12.1"
CERT_MANAGER_VERSION="v1.17.1"
KUBE_PROM_STACK_VERSION="69.3.0"
LOKI_VERSION="6.25.0"
PROMTAIL_VERSION="6.16.6"
RANCHER_VERSION="2.10.3"
CROWDSEC_VERSION="0.22.0"

# CrowdSec controller image (ingress-nginx rebuild with Lua support)
CROWDSEC_CONTROLLER_TAG="v1.13.2"
CROWDSEC_CONTROLLER_DIGEST="sha256:4575be24781cad35f8e58437db6a3f492df2a3167fed2b6759a6ff0dc3488d56"

# =============================================================================
# Preflight
# =============================================================================
require_root
ensure_tmux "$@"

banner "Platform Stack — init.pods.sh"

# RKE2 installs kubectl to a non-standard path. This script runs as root via
# sudo (not an interactive login shell) so .bashrc is not sourced and PATH
# does not include the RKE2 bin directory. Export both PATH and KUBECONFIG
# explicitly to ensure kubectl can find the binary and the cluster credentials.
export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# Confirm RKE2 server is installed on this node (kubectl binary exists)
if ! command -v kubectl &>/dev/null; then
    err "kubectl not found. Is RKE2 installed on this node?"
    exit 1
fi

# Confirm the API server is reachable and this node has a valid kubeconfig
if ! kubectl get nodes &>/dev/null; then
    err "Cannot connect to cluster. Is this a server node with RKE2 running?"
    exit 1
fi

separator "Cluster Status"
kubectl get nodes -o wide
echo ""

# Warn about NotReady nodes — deploying to a partial cluster can cause pods
# stuck in Pending when resources are insufficient (e.g., DaemonSets waiting
# for worker nodes that haven't finished joining)
NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "NotReady" || true)
if [[ "$NOT_READY" -gt 0 ]]; then
    warn "${NOT_READY} node(s) are NotReady!"
    if ! ask_yesno "Continue anyway?" "n"; then
        exit 1
    fi
fi

# =============================================================================
# Component Selection
# =============================================================================

# Multi-select defaults: everything enabled except Rancher. Rancher is an
# optional management UI that adds overhead (3 replicas by default) and is not
# needed for clusters managed via kubectl/GitOps.
ask_multiselect "Select components to install:" \
    "Helm|Package manager (required by Helm charts)|on" \
    "local-path-provisioner|Node-local storage for PVCs|on" \
    "ingress-nginx|Ingress controller with Proxy Protocol|on" \
    "cert-manager|Let's Encrypt TLS certificates|on" \
    "Monitoring|Prometheus + Grafana + Alertmanager|on" \
    "Logging|Loki + Promtail|on" \
    "CrowdSec|WAF + bot protection for ingress (L7)|off" \
    "Rancher|Kubernetes management UI|off"

INSTALL_HELM="${MULTISELECT_RESULT[0]}"
INSTALL_STORAGE="${MULTISELECT_RESULT[1]}"
INSTALL_INGRESS="${MULTISELECT_RESULT[2]}"
INSTALL_CERTMGR="${MULTISELECT_RESULT[3]}"
INSTALL_MONITORING="${MULTISELECT_RESULT[4]}"
INSTALL_LOGGING="${MULTISELECT_RESULT[5]}"
INSTALL_CROWDSEC="${MULTISELECT_RESULT[6]}"
INSTALL_RANCHER="${MULTISELECT_RESULT[7]}"

# --- Dependency auto-resolution ---
# Prevents broken deployments caused by missing prerequisites. Each rule
# force-enables the upstream component when a downstream one is selected.

# Rancher needs cert-manager (TLS certificate provisioning) and ingress-nginx
# (HTTP routing to the Rancher pods)
if [[ "$INSTALL_RANCHER" == "on" ]]; then
    if [[ "$INSTALL_CERTMGR" != "on" || "$INSTALL_INGRESS" != "on" ]]; then
        warn "Rancher requires cert-manager and ingress-nginx. Enabling them."
        INSTALL_CERTMGR="on"
        INSTALL_INGRESS="on"
    fi
fi

# CrowdSec bounces at the ingress level — requires ingress-nginx
if [[ "$INSTALL_CROWDSEC" == "on" ]]; then
    if [[ "$INSTALL_INGRESS" != "on" ]]; then
        warn "CrowdSec requires ingress-nginx. Enabling it."
        INSTALL_INGRESS="on"
    fi
fi

# Monitoring and Logging need PersistentVolumeClaims for data persistence
# (Prometheus TSDB, Alertmanager state, Grafana dashboards, Loki chunks).
# local-path-provisioner provides the default StorageClass for those PVCs.
if [[ "$INSTALL_MONITORING" == "on" || "$INSTALL_LOGGING" == "on" ]]; then
    if [[ "$INSTALL_STORAGE" != "on" ]]; then
        warn "Monitoring/Logging need storage. Enabling local-path-provisioner."
        INSTALL_STORAGE="on"
    fi
fi

# Any Helm chart obviously needs the Helm binary installed first
NEEDS_HELM="off"
for comp in "$INSTALL_STORAGE" "$INSTALL_INGRESS" "$INSTALL_CERTMGR" "$INSTALL_MONITORING" "$INSTALL_LOGGING" "$INSTALL_CROWDSEC" "$INSTALL_RANCHER"; do
    [[ "$comp" == "on" ]] && NEEDS_HELM="on"
done
if [[ "$NEEDS_HELM" == "on" && "$INSTALL_HELM" != "on" ]]; then
    warn "Selected components require Helm. Enabling it."
    INSTALL_HELM="on"
fi

# =============================================================================
# Per-Component Configuration
# =============================================================================

# --- ingress-nginx ---
LB_PRIVATE_IP="10.0.0.8"
if [[ "$INSTALL_INGRESS" == "on" ]]; then
    separator "Configure: ingress-nginx"

    # The LB private IP is used in proxy-real-ip-cidr to trust Proxy Protocol
    # headers from ONLY this IP. This prevents IP spoofing from other sources
    # that could forge X-Forwarded-For headers.
    ask_input "Load balancer private IP" "$LB_PRIVATE_IP"
    LB_PRIVATE_IP="$REPLY"

    # Proxy Protocol ordering warning: nginx expects PP-wrapped packets from
    # the very first connection. The LB must NOT send PP until nginx is ready,
    # and port 6443 (Kubernetes API) must NEVER use PP (kubectl doesn't speak it).
    echo ""
    warn "═══════════════════════════════════════════════════════════════"
    warn "  PROXY PROTOCOL ORDERING:"
    warn "  1. Install ingress-nginx first (expects Proxy Protocol)"
    warn "  2. THEN enable Proxy Protocol on LB ports 80/443"
    warn "  3. NEVER enable Proxy Protocol on port 6443"
    warn "═══════════════════════════════════════════════════════════════"
    echo ""
fi

# --- cert-manager ---
CERT_EMAIL=""
CERT_ISSUERS="both"
CERT_DOMAIN=""
if [[ "$INSTALL_CERTMGR" == "on" ]]; then
    separator "Configure: cert-manager"
    ask_input "Email for Let's Encrypt" ""
    CERT_EMAIL="$REPLY"

    # ClusterIssuer selection: staging has no rate limits but issues untrusted
    # certs (good for testing); production is rate-limited (50 certs/week/domain)
    # but issues real browser-trusted certs.
    ask_choice "ClusterIssuers to create?" 2 \
        "Staging only|For testing (untrusted certs)" \
        "Both staging + production|Recommended" \
        "Production only|Real certs (rate-limited)"
    case $REPLY in
        1) CERT_ISSUERS="staging" ;;
        2) CERT_ISSUERS="both" ;;
        3) CERT_ISSUERS="prod" ;;
    esac

    ask_input "Domain (for cert hostnames)" "yourdomain.com"
    CERT_DOMAIN="$REPLY"
fi

# --- Monitoring ---
GRAFANA_PASSWORD=""
GRAFANA_HOST=""
GRAFANA_ISSUER=""
PROM_RETENTION="30d"
PROM_STORAGE="50Gi"
AM_STORAGE="5Gi"
if [[ "$INSTALL_MONITORING" == "on" ]]; then
    separator "Configure: Monitoring"

    echo "Grafana admin password (leave empty to auto-generate):"
    ask_password "Password" 0
    GRAFANA_PASSWORD="$REPLY"
    if [[ -z "$GRAFANA_PASSWORD" ]]; then
        GRAFANA_PASSWORD="$(openssl rand -base64 16)"
        info "Auto-generated Grafana password: ${GRAFANA_PASSWORD}"
    fi

    DEFAULT_GRAFANA_HOST="grafana.${CERT_DOMAIN:-yourdomain.com}"
    ask_input "Grafana hostname" "$DEFAULT_GRAFANA_HOST"
    GRAFANA_HOST="$REPLY"

    if [[ "$INSTALL_CERTMGR" == "on" ]]; then
        ask_choice "TLS issuer for Grafana?" 1 \
            "letsencrypt-staging|Test first" \
            "letsencrypt-prod|Production cert"
        [[ $REPLY -eq 1 ]] && GRAFANA_ISSUER="letsencrypt-staging" || GRAFANA_ISSUER="letsencrypt-prod"
    fi

    # Prometheus retention 30d + 50Gi: 30 days of metrics history; 50Gi
    # accommodates ~100 time series per pod for a small-medium cluster
    ask_input "Prometheus retention" "$PROM_RETENTION"
    PROM_RETENTION="$REPLY"
    ask_input "Prometheus storage" "$PROM_STORAGE"
    PROM_STORAGE="$REPLY"

    # Alertmanager 5Gi: stores alert state and silences, much less data than Prometheus
    ask_input "Alertmanager storage" "$AM_STORAGE"
    AM_STORAGE="$REPLY"
fi

# --- Logging ---
LOKI_RETENTION="336h"
LOKI_STORAGE="50Gi"
if [[ "$INSTALL_LOGGING" == "on" ]]; then
    separator "Configure: Logging"
    # 336h = 14 days; longer retention needs more storage
    ask_input "Loki retention (hours)" "$LOKI_RETENTION"
    LOKI_RETENTION="$REPLY"
    ask_input "Loki storage size" "$LOKI_STORAGE"
    LOKI_STORAGE="$REPLY"
fi

# --- CrowdSec ---
CROWDSEC_BOUNCER_KEY=""
CROWDSEC_ENROLL_KEY=""
if [[ "$INSTALL_CROWDSEC" == "on" ]]; then
    separator "Configure: CrowdSec"

    # Bouncer API key: authenticates the ingress-nginx Lua bouncer to LAPI.
    # Auto-generated for security; manual entry not needed.
    CROWDSEC_BOUNCER_KEY="$(openssl rand -hex 32)"

    # Console enrollment: optional, connects to CrowdSec console for
    # centralized dashboard, shared blocklists, and alert visibility.
    echo "CrowdSec console enrollment key (leave empty to skip):"
    echo "  Get one at: https://app.crowdsec.net"
    ask_input "Enrollment key" ""
    CROWDSEC_ENROLL_KEY="$REPLY"
fi

# --- Rancher ---
RANCHER_HOST=""
RANCHER_PASSWORD=""
RANCHER_REPLICAS="3"
RANCHER_ISSUER="letsencrypt-staging"
if [[ "$INSTALL_RANCHER" == "on" ]]; then
    separator "Configure: Rancher"
    DEFAULT_RANCHER_HOST="rancher.${CERT_DOMAIN:-yourdomain.com}"
    ask_input "Rancher hostname" "$DEFAULT_RANCHER_HOST"
    RANCHER_HOST="$REPLY"

    if [[ "$INSTALL_CERTMGR" == "on" ]]; then
        ask_choice "TLS issuer for Rancher?" 1 \
            "letsencrypt-staging|Test first" \
            "letsencrypt-prod|Production cert"
        [[ $REPLY -eq 1 ]] && RANCHER_ISSUER="letsencrypt-staging" || RANCHER_ISSUER="letsencrypt-prod"
    fi

    # Bootstrap password: one-time first-login password. The user is forced
    # to change it on first access via the Rancher UI.
    echo "Bootstrap password (leave empty to auto-generate):"
    ask_password "Password" 0
    RANCHER_PASSWORD="$REPLY"
    if [[ -z "$RANCHER_PASSWORD" ]]; then
        RANCHER_PASSWORD="$(openssl rand -base64 16)"
        info "Auto-generated Rancher password: ${RANCHER_PASSWORD}"
    fi

    # Replicas should match the number of server nodes for HA;
    # 3 is default for a 3-node control plane
    ask_input "Rancher replicas" "$RANCHER_REPLICAS"
    RANCHER_REPLICAS="$REPLY"
fi

# =============================================================================
# Confirmation
# =============================================================================
components=()
[[ "$INSTALL_HELM" == "on" ]] && components+=("Helm")
[[ "$INSTALL_STORAGE" == "on" ]] && components+=("local-path")
[[ "$INSTALL_INGRESS" == "on" ]] && components+=("ingress-nginx")
[[ "$INSTALL_CERTMGR" == "on" ]] && components+=("cert-manager")
[[ "$INSTALL_MONITORING" == "on" ]] && components+=("Monitoring")
[[ "$INSTALL_LOGGING" == "on" ]] && components+=("Logging")
[[ "$INSTALL_CROWDSEC" == "on" ]] && components+=("CrowdSec")
[[ "$INSTALL_RANCHER" == "on" ]] && components+=("Rancher")

print_summary "Deployment Plan" \
    "Components|${components[*]}" \
    "LB IP|${LB_PRIVATE_IP}" \
    "Domain|${CERT_DOMAIN:-n/a}"

if ! ask_yesno "Proceed with deployment?" "n"; then
    info "Aborted."
    exit 0
fi

# =============================================================================
# Deployment
# =============================================================================

# Bash associative array collecting all generated credentials during deployment.
# Written to a file at the end so the operator has a single reference for all
# passwords and URLs.
declare -A CREDENTIALS

# --- 1. Helm ---
if [[ "$INSTALL_HELM" == "on" ]]; then
    separator "Installing Helm"
    if command -v helm &>/dev/null; then
        log "Helm already installed: $(helm version --short 2>/dev/null)"
    else
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | \
            DESIRED_VERSION="$HELM_VERSION" bash
        log "Helm installed: $(helm version --short 2>/dev/null)"
    fi
fi

# --- 2. local-path-provisioner ---
# Provides node-local PersistentVolume storage using host directories.
# Set as the default StorageClass so PVCs that don't specify a class are
# automatically provisioned.
if [[ "$INSTALL_STORAGE" == "on" ]]; then
    separator "Installing local-path-provisioner"
    curl -fsSL -o "${TMPDIR_PODS}/local-path-storage.yaml" \
        "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
    echo "${LOCAL_PATH_SHA256}  ${TMPDIR_PODS}/local-path-storage.yaml" | sha256sum -c -
    kubectl apply -f "${TMPDIR_PODS}/local-path-storage.yaml"

    kubectl patch storageclass local-path \
        -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

    log "local-path-provisioner installed (default StorageClass)"
fi

# --- 3. CrowdSec ---
# Deploy LAPI + Agent + AppSec BEFORE ingress-nginx so the decision engine is
# running when the bouncer starts querying it.
if [[ "$INSTALL_CROWDSEC" == "on" ]]; then
    separator "Installing CrowdSec (LAPI + Agent + AppSec)"

    helm repo add crowdsec https://crowdsecurity.github.io/helm-charts 2>/dev/null || true
    helm repo update crowdsec

    # Build enrollment section conditionally
    CROWDSEC_ENROLL=""
    if [[ -n "$CROWDSEC_ENROLL_KEY" ]]; then
        CROWDSEC_ENROLL="
    - name: ENROLL_KEY
      value: \"${CROWDSEC_ENROLL_KEY}\"
    - name: ENROLL_INSTANCE_NAME
      value: \"$(hostname -f)\""
    fi

    cat > "${TMPDIR_PODS}/crowdsec-values.yaml" <<EOF
container_runtime: containerd

agent:
  acquisition:
    - namespace: ingress-nginx
      podName: ingress-nginx-controller-*
      program: nginx
  env:
    - name: COLLECTIONS
      value: "crowdsecurity/nginx"

lapi:
  env:
    - name: BOUNCER_KEY_ingress
      value: "${CROWDSEC_BOUNCER_KEY}"${CROWDSEC_ENROLL}
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      memory: 256Mi

appsec:
  enabled: true
  acquisitions:
    - appsec_configs:
        - crowdsecurity/appsec-default
      labels:
        type: appsec
      listen_addr: 0.0.0.0:7422
      path: /
      source: appsec
  env:
    - name: COLLECTIONS
      value: "crowdsecurity/appsec-virtual-patching crowdsecurity/appsec-generic-rules"
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      memory: 256Mi
EOF

    helm upgrade --install crowdsec crowdsec/crowdsec \
        --namespace crowdsec \
        --create-namespace \
        --version "$CROWDSEC_VERSION" \
        -f "${TMPDIR_PODS}/crowdsec-values.yaml"

    log "CrowdSec installed (LAPI + Agent + AppSec)"
fi

# --- 4. ingress-nginx ---
if [[ "$INSTALL_INGRESS" == "on" ]]; then
    separator "Installing ingress-nginx"

    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
    helm repo update ingress-nginx

    # Pre-flight: the DaemonSet nodeSelector requires this label. If no nodes
    # have it, 0 ingress pods are scheduled — no error, just no ingress.
    WORKER_COUNT=$(kubectl get nodes -l node-role.kubernetes.io/worker=worker --no-headers 2>/dev/null | wc -l)
    if [[ "$WORKER_COUNT" -eq 0 ]]; then
        warn "No nodes have label node-role.kubernetes.io/worker=worker"
        warn "ingress-nginx DaemonSet will schedule 0 pods!"
        warn "Label workers: kubectl label node <name> node-role.kubernetes.io/worker=worker"
        if ! ask_yesno "Continue anyway?" "n"; then
            exit 1
        fi
    fi

    # --- ingress-nginx values explained ---
    #
    # DaemonSet + hostPort: runs one ingress pod per worker node, binding ports
    # 80/443 directly on the host. No Kubernetes LoadBalancer service needed —
    # the external LB (e.g., Hetzner) points directly to worker node IPs.
    #
    # service.enabled: false — disables the cloud-native LoadBalancer service
    # since traffic arrives via the external LB to hostPorts.
    #
    # nodeSelector worker — ingress pods only on workers, keeping control plane
    # nodes dedicated to cluster operations.
    #
    # use-proxy-protocol: "true" — parse Proxy Protocol v1/v2 headers to extract
    # the real client IP (the LB wraps each TCP connection with a PP header).
    #
    # proxy-real-ip-cidr — trust PP headers from ONLY the LB private IP.
    # Security: prevents IP spoofing from other sources.
    #
    # use-forwarded-headers + compute-full-forwarded-for — propagate the real
    # client IP via X-Forwarded-For so applications can use it.
    #
    # hide-headers: Server,X-Powered-By — security: don't leak server software info.
    #
    # hsts: true + 1 year + includeSubdomains — enforce HTTPS for all future visits.
    #
    # proxy-body-size: 50m — allow file uploads up to 50MB (default 1m is too
    # restrictive for most applications).
    #
    # proxy-read-timeout/proxy-send-timeout: 120 — 2 minutes for long requests
    # (webhooks, file uploads, slow API responses).
    #
    # ssl-protocols: TLSv1.2 TLSv1.3 — TLS 1.0/1.1 are deprecated due to known
    # vulnerabilities (POODLE, BEAST).
    #
    # log-format-upstream — custom log format includes upstream name, address,
    # response time, and request ID for debugging request routing issues.
    #
    # admissionWebhooks — validates Ingress resources at creation time, catching
    # misconfigurations (duplicate paths, invalid annotations) before deployment.
    #
    # metrics + serviceMonitor — enables Prometheus to auto-discover and scrape
    # nginx metrics (request rate, latency, error rate, connection count).
    #
    # Resource limits 256Mi — caps memory to prevent runaway growth from large
    # request buffering.

    # CrowdSec bouncer integration: swap controller image to include Lua,
    # inject bouncer plugin via init container, configure LAPI connection.
    CROWDSEC_IMAGE=""
    CROWDSEC_VOLUMES=""
    CROWDSEC_INIT=""
    CROWDSEC_MOUNTS=""
    CROWDSEC_CONFIG=""
    if [[ "$INSTALL_CROWDSEC" == "on" ]]; then
        CROWDSEC_IMAGE="
  image:
    registry: docker.io
    image: crowdsecurity/controller
    tag: \"${CROWDSEC_CONTROLLER_TAG}\"
    digest: \"${CROWDSEC_CONTROLLER_DIGEST}\""

        CROWDSEC_VOLUMES="
  extraVolumes:
    - name: crowdsec-bouncer-plugin
      emptyDir: {}"

        CROWDSEC_INIT="
  extraInitContainers:
    - name: init-clone-crowdsec-bouncer
      image: crowdsecurity/lua-bouncer-plugin
      imagePullPolicy: IfNotPresent
      env:
        - name: API_URL
          value: \"http://crowdsec-service.crowdsec.svc.cluster.local:8080\"
        - name: API_KEY
          value: \"${CROWDSEC_BOUNCER_KEY}\"
        - name: BOUNCER_CONFIG
          value: \"/crowdsec/crowdsec-bouncer.conf\"
        - name: APPSEC_URL
          value: \"http://crowdsec-appsec-service.crowdsec.svc.cluster.local:7422\"
        - name: APPSEC_FAILURE_ACTION
          value: \"passthrough\"
        - name: APPSEC_CONNECT_TIMEOUT
          value: \"100\"
        - name: APPSEC_SEND_TIMEOUT
          value: \"100\"
        - name: APPSEC_PROCESS_TIMEOUT
          value: \"1000\"
        - name: ALWAYS_SEND_TO_APPSEC
          value: \"false\"
      command: ['sh', '-c', 'sh /docker_start.sh; mkdir -p /lua_plugins/crowdsec/; cp -R /crowdsec/* /lua_plugins/crowdsec/']
      volumeMounts:
        - name: crowdsec-bouncer-plugin
          mountPath: /lua_plugins"

        CROWDSEC_MOUNTS="
  extraVolumeMounts:
    - name: crowdsec-bouncer-plugin
      mountPath: /etc/nginx/lua/plugins/crowdsec
      subPath: crowdsec"

        CROWDSEC_CONFIG="
    plugins: \"crowdsec\"
    lua-shared-dicts: \"crowdsec_cache: 50m\"
    server-snippet: |
      lua_ssl_trusted_certificate \"/etc/ssl/certs/ca-certificates.crt\";
      resolver local=on ipv6=off;"
    fi

    cat > "${TMPDIR_PODS}/ingress-nginx-values.yaml" <<EOF
controller:${CROWDSEC_IMAGE}
  kind: DaemonSet
  hostPort:
    enabled: true
  service:
    enabled: false
  nodeSelector:
    node-role.kubernetes.io/worker: "worker"
  config:
    use-proxy-protocol: "true"
    use-forwarded-headers: "true"
    compute-full-forwarded-for: "true"
    proxy-real-ip-cidr: "${LB_PRIVATE_IP}/32"
    hide-headers: "Server,X-Powered-By"
    hsts: "true"
    hsts-max-age: "31536000"
    hsts-include-subdomains: "true"
    proxy-body-size: "50m"
    proxy-read-timeout: "120"
    proxy-send-timeout: "120"
    ssl-protocols: "TLSv1.2 TLSv1.3"
    ssl-prefer-server-ciphers: "true"
    log-format-upstream: >-
      \$remote_addr - \$remote_user [\$time_local] "\$request"
      \$status \$body_bytes_sent "\$http_referer" "\$http_user_agent"
      \$request_length \$request_time
      [\$proxy_upstream_name] \$upstream_addr
      \$upstream_response_length \$upstream_response_time \$upstream_status \$req_id${CROWDSEC_CONFIG}
  admissionWebhooks:
    enabled: true
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      namespace: monitoring
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      # No CPU limit: CFS throttling on an ingress controller causes latency
      # spikes under load. CPU request ensures scheduling; bursting is preferred.
      memory: 256Mi${CROWDSEC_VOLUMES}${CROWDSEC_INIT}${CROWDSEC_MOUNTS}
EOF

    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --version "$INGRESS_NGINX_VERSION" \
        -f "${TMPDIR_PODS}/ingress-nginx-values.yaml"

    log "ingress-nginx installed"

    # Remind the operator to enable Proxy Protocol on the LB NOW — nginx is
    # already expecting PP-wrapped connections on ports 80/443. Port 6443
    # (Kubernetes API) must never use PP because kubectl does not speak it.
    echo ""
    warn "═══════════════════════════════════════════════════════════════"
    warn "  NEXT: Enable Proxy Protocol on Hetzner LB for ports 80/443"
    warn "  DO NOT enable Proxy Protocol on port 6443!"
    warn "═══════════════════════════════════════════════════════════════"
    echo ""
    ask_yesno "Press Y when Proxy Protocol is enabled on LB (or skip)" "n" || true
fi

# --- 5. cert-manager ---
if [[ "$INSTALL_CERTMGR" == "on" ]]; then
    separator "Installing cert-manager"

    helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
    helm repo update jetstack

    # crds.enabled=true installs Custom Resource Definitions (Certificate,
    # ClusterIssuer, etc.) as part of the Helm chart, avoiding a separate
    # kubectl apply step for CRDs.
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version "$CERT_MANAGER_VERSION" \
        --set crds.enabled=true \
        --set resources.requests.cpu=50m \
        --set resources.requests.memory=64Mi \
        --wait --timeout 300s

    log "cert-manager installed"

    # Helm --wait ensures all pods are ready, but the webhook needs a few
    # extra seconds to register its API service endpoint with the API server.
    info "Waiting for cert-manager webhook to register..."
    sleep 10

    # ClusterIssuer (not Issuer): works across ALL namespaces, so one issuer
    # serves the whole cluster. Uses ACME HTTP-01 solver, which proves domain
    # ownership by serving a challenge token via the nginx ingress class.

    # Staging server: no rate limits, issues untrusted certs, use for testing
    if [[ "$CERT_ISSUERS" == "staging" || "$CERT_ISSUERS" == "both" ]]; then
        kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${CERT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
        log "ClusterIssuer: letsencrypt-staging"
    fi

    # Production server: rate-limited (50 certs/week/domain), issues real
    # browser-trusted certificates
    if [[ "$CERT_ISSUERS" == "prod" || "$CERT_ISSUERS" == "both" ]]; then
        kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${CERT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
        log "ClusterIssuer: letsencrypt-prod"
    fi
fi

# --- 6. Monitoring ---
# kube-prometheus-stack is a meta-chart bundling: Prometheus (metrics collection),
# Grafana (dashboards), Alertmanager (alert routing), node-exporter (host metrics),
# and kube-state-metrics (Kubernetes object metrics).
if [[ "$INSTALL_MONITORING" == "on" ]]; then
    separator "Installing Monitoring (Prometheus + Grafana + Alertmanager)"

    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update prometheus-community

    # Build Grafana ingress section conditionally.
    # The cert-manager.io/cluster-issuer annotation auto-provisions a TLS
    # certificate for the Grafana hostname.
    GRAFANA_INGRESS=""
    if [[ -n "$GRAFANA_ISSUER" && -n "$GRAFANA_HOST" ]]; then
        GRAFANA_INGRESS="
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      cert-manager.io/cluster-issuer: \"${GRAFANA_ISSUER}\"
    hosts:
      - ${GRAFANA_HOST}
    tls:
      - secretName: grafana-tls
        hosts:
          - ${GRAFANA_HOST}"
    fi

    # Pre-configure Loki as a Grafana data source if logging is also being
    # installed. This saves manual setup — Grafana will have both Prometheus
    # and Loki available out of the box.
    LOKI_DS=""
    if [[ "$INSTALL_LOGGING" == "on" ]]; then
        LOKI_DS="
  additionalDataSources:
    - name: Loki
      type: loki
      url: http://loki:3100
      access: proxy
      isDefault: false"
    fi

    # --- Monitoring values explained ---
    #
    # serviceMonitorSelectorNilUsesHelmValues: false — scrape ALL ServiceMonitors
    # in the cluster, not just those from this Helm release. Critical for
    # monitoring ingress-nginx, cert-manager, and other components.
    #
    # podMonitorSelectorNilUsesHelmValues: false — same for PodMonitors.
    #
    # Prometheus retention 30d + 50Gi: 30 days of metrics; 50Gi accommodates
    # ~100 time series per pod for a small-medium cluster.
    #
    # Alertmanager 5Gi: stores alert state and silences; much less data than
    # Prometheus.
    #
    # Grafana persistence 10Gi: keeps custom dashboards and settings across pod
    # restarts (without persistence, dashboards reset on every restart).
    #
    # Resource limits: right-sized for small-medium clusters. Prometheus gets
    # the most (2Gi limit) as it holds all metrics in memory.
    #
    # Default rules: etcd health, API server latency, node recording rules —
    # provides alerting out of the box.
    cat > "${TMPDIR_PODS}/monitoring-values.yaml" <<EOF
prometheus:
  prometheusSpec:
    retention: ${PROM_RETENTION}
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: ${PROM_STORAGE}
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        memory: 2Gi

alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: ${AM_STORAGE}
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        memory: 128Mi

grafana:
  adminPassword: "${GRAFANA_PASSWORD}"
  persistence:
    enabled: true
    storageClassName: local-path
    size: 10Gi${GRAFANA_INGRESS}
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      memory: 256Mi${LOKI_DS}

nodeExporter:
  resources:
    requests:
      cpu: 50m
      memory: 32Mi
    limits:
      memory: 64Mi

kubeStateMetrics:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      memory: 128Mi

defaultRules:
  create: true
  rules:
    etcd: true
    kubeApiserver: true
    kubePrometheusNodeRecording: true
EOF

    helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --create-namespace \
        --version "$KUBE_PROM_STACK_VERSION" \
        -f "${TMPDIR_PODS}/monitoring-values.yaml"

    CREDENTIALS["Grafana URL"]="https://${GRAFANA_HOST}"
    CREDENTIALS["Grafana user"]="admin"
    CREDENTIALS["Grafana password"]="${GRAFANA_PASSWORD}"

    log "Monitoring stack installed"
fi

# --- 7. Logging ---
# Loki + Promtail: Loki stores logs, Promtail ships them from every node.
# Both deployed in the monitoring namespace, co-located with Prometheus/Grafana
# for simplified network policies and service discovery.
if [[ "$INSTALL_LOGGING" == "on" ]]; then
    separator "Installing Logging (Loki + Promtail)"

    helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
    helm repo update grafana

    # --- Loki values explained ---
    #
    # SingleBinary mode: simplest deployment (one pod does ingestion, storage,
    # and querying). Appropriate for single-cluster setups; for large scale,
    # switch to microservices mode.
    #
    # TSDB + filesystem storage: no object storage (S3/GCS) required; works
    # with local-path-provisioner PVCs.
    #
    # Schema v13: latest Loki schema version for index and chunk format.
    #
    # retention_period: 336h (14 days); longer retention needs more storage.
    #
    # compactor.retention_enabled: true — Loki does NOT delete old data unless
    # the compactor is explicitly told to enforce retention.
    #
    # Gateway disabled: the Loki gateway adds authentication/routing but is
    # unnecessary for in-cluster access where Promtail pushes directly.
    cat > "${TMPDIR_PODS}/loki-values.yaml" <<EOF
loki:
  deploymentMode: SingleBinary
  singleBinary:
    replicas: 1
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        memory: 1Gi
  storage:
    type: filesystem
  limits_config:
    retention_period: ${LOKI_RETENTION}
  compactor:
    retention_enabled: true
  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: index_
          period: 24h
  persistence:
    enabled: true
    storageClassName: local-path
    size: ${LOKI_STORAGE}
  gateway:
    enabled: false
promtail:
  enabled: false
EOF

    helm upgrade --install loki grafana/loki \
        --namespace monitoring \
        --version "$LOKI_VERSION" \
        -f "${TMPDIR_PODS}/loki-values.yaml"

    # Promtail: DaemonSet that runs on every node, tails container log files
    # from /var/log/pods, and pushes them to Loki.
    cat > "${TMPDIR_PODS}/promtail-values.yaml" <<EOF
config:
  clients:
    - url: http://loki:3100/loki/api/v1/push
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    memory: 128Mi
EOF

    helm upgrade --install promtail grafana/promtail \
        --namespace monitoring \
        --version "$PROMTAIL_VERSION" \
        -f "${TMPDIR_PODS}/promtail-values.yaml"

    log "Loki + Promtail installed"
fi

# --- 8. Rancher ---
if [[ "$INSTALL_RANCHER" == "on" ]]; then
    separator "Installing Rancher"

    # rancher-stable: production-grade releases only (vs rancher-latest which
    # includes release candidates)
    helm repo add rancher-stable https://releases.rancher.com/server-charts/stable 2>/dev/null || true
    helm repo update rancher-stable

    # ingress.tls.source=secret — use the ClusterIssuer created by cert-manager
    # (installed earlier) instead of Rancher's built-in Let's Encrypt integration.
    # This avoids duplicate issuers and rate-limit contention.
    # cattle-system: Rancher's conventional namespace.
    cat > "${TMPDIR_PODS}/rancher-values.yaml" <<EOF
hostname: "${RANCHER_HOST}"
ingress:
  tls:
    source: secret
  extraAnnotations:
    cert-manager.io/cluster-issuer: "${RANCHER_ISSUER}"
replicas: ${RANCHER_REPLICAS}
bootstrapPassword: "${RANCHER_PASSWORD}"
resources:
  requests:
    cpu: 250m
    memory: 256Mi
  limits:
    memory: 1Gi
EOF

    helm upgrade --install rancher rancher-stable/rancher \
        --namespace cattle-system \
        --create-namespace \
        --version "$RANCHER_VERSION" \
        -f "${TMPDIR_PODS}/rancher-values.yaml"

    CREDENTIALS["Rancher URL"]="https://${RANCHER_HOST}"
    CREDENTIALS["Rancher password"]="${RANCHER_PASSWORD}"

    log "Rancher installed"
fi

# =============================================================================
# Post-Deployment Hardening
# =============================================================================

# --- Pod Security Standards ---
# baseline: blocks known privilege escalations (hostPID, privileged containers)
# restricted (warn only): flags non-root, read-only rootfs violations without blocking
separator "Pod Security Standards"
for ns in monitoring ingress-nginx cert-manager cattle-system crowdsec; do
    if kubectl get namespace "$ns" &>/dev/null; then
        kubectl label namespace "$ns" \
            pod-security.kubernetes.io/enforce=baseline \
            pod-security.kubernetes.io/warn=restricted \
            --overwrite
    fi
done
log "Pod Security Standards labels applied"

# --- Network Policies ---
# Default-deny ingress + selective allow: prevents lateral movement between
# namespaces while allowing monitoring components to communicate.
if [[ "$INSTALL_MONITORING" == "on" || "$INSTALL_LOGGING" == "on" ]]; then
    separator "Network Policies (monitoring)"
    kubectl apply -f - <<'EOPOLICY'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: monitoring
spec:
  podSelector: {}
  policyTypes:
    - Ingress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-intra-monitoring
  namespace: monitoring
spec:
  podSelector: {}
  ingress:
    - from:
        - podSelector: {}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-grafana-from-ingress
  namespace: monitoring
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: grafana
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - port: 3000
EOPOLICY
    log "Network policies applied (monitoring namespace)"
fi

# =============================================================================
# Final Output
# =============================================================================
separator "Deployment Complete"

# Display all collected credentials in a summary box
if [[ ${#CREDENTIALS[@]} -gt 0 ]]; then
    cred_args=()
    for key in "${!CREDENTIALS[@]}"; do
        cred_args+=("${key}|${CREDENTIALS[$key]}")
    done
    print_summary "Credentials (save these!)" "${cred_args[@]}"
fi

# Quick visual check that all components are starting correctly
echo ""
info "Pod status:"
kubectl get pods -A --sort-by=.metadata.namespace 2>/dev/null | head -40
echo ""

# Actionable reminders for post-deployment tasks
info "Next steps:"
[[ "$INSTALL_INGRESS" == "on" ]] && info "  - Enable Proxy Protocol on Hetzner LB for ports 80/443 (if not done)"
[[ "$INSTALL_CERTMGR" == "on" ]] && info "  - Verify ClusterIssuers: kubectl get clusterissuer"
[[ "$INSTALL_MONITORING" == "on" ]] && info "  - Access Grafana: https://${GRAFANA_HOST}"
[[ "$INSTALL_RANCHER" == "on" ]] && info "  - Access Rancher: https://${RANCHER_HOST}"
[[ "$INSTALL_CROWDSEC" == "on" ]] && info "  - Verify CrowdSec: kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli metrics"
info "  - Deploy customer namespaces with network policies"
info "  - Switch Grafana to letsencrypt-prod when ready"

# Save credentials to /root/platform-credentials.txt (mode 600 = root-only
# readable) so the operator has a persistent record of all generated passwords
CRED_FILE="/root/platform-credentials.txt"
{
    echo "================================================================================"
    echo "Platform Stack Credentials"
    echo "Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "================================================================================"
    for key in "${!CREDENTIALS[@]}"; do
        printf "  %-24s %s\n" "${key}:" "${CREDENTIALS[$key]}"
    done
    echo "================================================================================"
} > "$CRED_FILE"
chmod 600 "$CRED_FILE"
log "Credentials saved to ${CRED_FILE}"
