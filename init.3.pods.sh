#!/usr/bin/env bash
# =============================================================================
# init.pods.sh — Platform Stack Deployment via Helm
# Deploys: Helm, local-path, ingress-nginx, cert-manager, monitoring, logging, Rancher
# Run once on a server node after all nodes have joined.
#
# Usage: sudo ./init.pods.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# =============================================================================
# Preflight
# =============================================================================
require_root

banner "Platform Stack — init.pods.sh"

# Ensure kubectl works
export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

if ! command -v kubectl &>/dev/null; then
    err "kubectl not found. Is RKE2 installed on this node?"
    exit 1
fi

if ! kubectl get nodes &>/dev/null; then
    err "Cannot connect to cluster. Is this a server node with RKE2 running?"
    exit 1
fi

separator "Cluster Status"
kubectl get nodes -o wide
echo ""

# Warn about NotReady nodes
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
ask_multiselect "Select components to install:" \
    "Helm|Package manager (required by Helm charts)|on" \
    "local-path-provisioner|Node-local storage for PVCs|on" \
    "ingress-nginx|Ingress controller with Proxy Protocol|on" \
    "cert-manager|Let's Encrypt TLS certificates|on" \
    "Monitoring|Prometheus + Grafana + Alertmanager|on" \
    "Logging|Loki + Promtail|on" \
    "Rancher|Kubernetes management UI|off"

INSTALL_HELM="${MULTISELECT_RESULT[0]}"
INSTALL_STORAGE="${MULTISELECT_RESULT[1]}"
INSTALL_INGRESS="${MULTISELECT_RESULT[2]}"
INSTALL_CERTMGR="${MULTISELECT_RESULT[3]}"
INSTALL_MONITORING="${MULTISELECT_RESULT[4]}"
INSTALL_LOGGING="${MULTISELECT_RESULT[5]}"
INSTALL_RANCHER="${MULTISELECT_RESULT[6]}"

# Enforce dependencies
if [[ "$INSTALL_RANCHER" == "on" ]]; then
    if [[ "$INSTALL_CERTMGR" != "on" || "$INSTALL_INGRESS" != "on" ]]; then
        warn "Rancher requires cert-manager and ingress-nginx. Enabling them."
        INSTALL_CERTMGR="on"
        INSTALL_INGRESS="on"
    fi
fi

if [[ "$INSTALL_MONITORING" == "on" || "$INSTALL_LOGGING" == "on" ]]; then
    if [[ "$INSTALL_STORAGE" != "on" ]]; then
        warn "Monitoring/Logging need storage. Enabling local-path-provisioner."
        INSTALL_STORAGE="on"
    fi
fi

# Check if any Helm chart is selected
NEEDS_HELM="off"
for comp in "$INSTALL_STORAGE" "$INSTALL_INGRESS" "$INSTALL_CERTMGR" "$INSTALL_MONITORING" "$INSTALL_LOGGING" "$INSTALL_RANCHER"; do
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
    ask_input "Load balancer private IP" "$LB_PRIVATE_IP"
    LB_PRIVATE_IP="$REPLY"

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

    ask_input "Prometheus retention" "$PROM_RETENTION"
    PROM_RETENTION="$REPLY"
    ask_input "Prometheus storage" "$PROM_STORAGE"
    PROM_STORAGE="$REPLY"
    ask_input "Alertmanager storage" "$AM_STORAGE"
    AM_STORAGE="$REPLY"
fi

# --- Logging ---
LOKI_RETENTION="336h"
LOKI_STORAGE="50Gi"
if [[ "$INSTALL_LOGGING" == "on" ]]; then
    separator "Configure: Logging"
    ask_input "Loki retention (hours)" "$LOKI_RETENTION"
    LOKI_RETENTION="$REPLY"
    ask_input "Loki storage size" "$LOKI_STORAGE"
    LOKI_STORAGE="$REPLY"
fi

# --- Rancher ---
RANCHER_HOST=""
RANCHER_PASSWORD=""
RANCHER_REPLICAS="3"
if [[ "$INSTALL_RANCHER" == "on" ]]; then
    separator "Configure: Rancher"
    DEFAULT_RANCHER_HOST="rancher.${CERT_DOMAIN:-yourdomain.com}"
    ask_input "Rancher hostname" "$DEFAULT_RANCHER_HOST"
    RANCHER_HOST="$REPLY"

    echo "Bootstrap password (leave empty to auto-generate):"
    ask_password "Password" 0
    RANCHER_PASSWORD="$REPLY"
    if [[ -z "$RANCHER_PASSWORD" ]]; then
        RANCHER_PASSWORD="$(openssl rand -base64 16)"
        info "Auto-generated Rancher password: ${RANCHER_PASSWORD}"
    fi

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

# Track credentials for final output
declare -A CREDENTIALS

# --- 1. Helm ---
if [[ "$INSTALL_HELM" == "on" ]]; then
    separator "Installing Helm"
    if command -v helm &>/dev/null; then
        log "Helm already installed: $(helm version --short 2>/dev/null)"
    else
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        log "Helm installed: $(helm version --short 2>/dev/null)"
    fi
fi

# --- 2. local-path-provisioner ---
if [[ "$INSTALL_STORAGE" == "on" ]]; then
    separator "Installing local-path-provisioner"
    kubectl apply -f \
        https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml

    kubectl patch storageclass local-path \
        -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

    log "local-path-provisioner installed (default StorageClass)"
fi

# --- 3. ingress-nginx ---
if [[ "$INSTALL_INGRESS" == "on" ]]; then
    separator "Installing ingress-nginx"

    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
    helm repo update

    cat > /tmp/ingress-nginx-values.yaml <<EOF
controller:
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
      \$upstream_response_length \$upstream_response_time \$upstream_status \$req_id
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
      memory: 256Mi
EOF

    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        -f /tmp/ingress-nginx-values.yaml

    log "ingress-nginx installed"

    echo ""
    warn "═══════════════════════════════════════════════════════════════"
    warn "  NEXT: Enable Proxy Protocol on Hetzner LB for ports 80/443"
    warn "  DO NOT enable Proxy Protocol on port 6443!"
    warn "═══════════════════════════════════════════════════════════════"
    echo ""
    ask_yesno "Press Y when Proxy Protocol is enabled on LB (or skip)" "n" || true
fi

# --- 4. cert-manager ---
if [[ "$INSTALL_CERTMGR" == "on" ]]; then
    separator "Installing cert-manager"

    helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
    helm repo update

    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --set crds.enabled=true \
        --set resources.requests.cpu=50m \
        --set resources.requests.memory=64Mi

    log "cert-manager installed"

    info "Waiting for cert-manager webhook to be ready..."
    kubectl wait --for=condition=available deployment/cert-manager-webhook \
        -n cert-manager --timeout=120s 2>/dev/null || sleep 30

    # ClusterIssuers
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

# --- 5. Monitoring ---
if [[ "$INSTALL_MONITORING" == "on" ]]; then
    separator "Installing Monitoring (Prometheus + Grafana + Alertmanager)"

    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update

    # Build Grafana ingress section conditionally
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

    # Loki datasource (pre-configure if logging is also being installed)
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

    cat > /tmp/monitoring-values.yaml <<EOF
prometheus:
  prometheusSpec:
    retention: ${PROM_RETENTION}
    storageSpec:
      volumeClaimTemplate:
        spec:
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
        -f /tmp/monitoring-values.yaml

    CREDENTIALS["Grafana URL"]="https://${GRAFANA_HOST}"
    CREDENTIALS["Grafana user"]="admin"
    CREDENTIALS["Grafana password"]="${GRAFANA_PASSWORD}"

    log "Monitoring stack installed"
fi

# --- 6. Logging ---
if [[ "$INSTALL_LOGGING" == "on" ]]; then
    separator "Installing Logging (Loki + Promtail)"

    helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
    helm repo update

    cat > /tmp/loki-values.yaml <<EOF
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
    size: ${LOKI_STORAGE}
  gateway:
    enabled: false
promtail:
  enabled: false
EOF

    helm upgrade --install loki grafana/loki \
        --namespace monitoring \
        -f /tmp/loki-values.yaml

    helm upgrade --install promtail grafana/promtail \
        --namespace monitoring \
        --set "config.clients[0].url=http://loki:3100/loki/api/v1/push"

    log "Loki + Promtail installed"
fi

# --- 7. Rancher ---
if [[ "$INSTALL_RANCHER" == "on" ]]; then
    separator "Installing Rancher"

    helm repo add rancher-stable https://releases.rancher.com/server-charts/stable 2>/dev/null || true
    helm repo update

    helm upgrade --install rancher rancher-stable/rancher \
        --namespace cattle-system \
        --create-namespace \
        --set hostname="${RANCHER_HOST}" \
        --set ingress.tls.source=letsEncrypt \
        --set "letsEncrypt.email=${CERT_EMAIL}" \
        --set letsEncrypt.ingress.class=nginx \
        --set "replicas=${RANCHER_REPLICAS}" \
        --set "bootstrapPassword=${RANCHER_PASSWORD}" \
        --set resources.requests.cpu=250m \
        --set resources.requests.memory=256Mi \
        --set resources.limits.memory=1Gi

    CREDENTIALS["Rancher URL"]="https://${RANCHER_HOST}"
    CREDENTIALS["Rancher password"]="${RANCHER_PASSWORD}"

    log "Rancher installed"
fi

# =============================================================================
# Final Output
# =============================================================================
separator "Deployment Complete"

# Credentials
if [[ ${#CREDENTIALS[@]} -gt 0 ]]; then
    cred_args=()
    for key in "${!CREDENTIALS[@]}"; do
        cred_args+=("${key}|${CREDENTIALS[$key]}")
    done
    print_summary "Credentials (save these!)" "${cred_args[@]}"
fi

echo ""
info "Pod status:"
kubectl get pods -A --sort-by=.metadata.namespace 2>/dev/null | head -40
echo ""

info "Next steps:"
[[ "$INSTALL_INGRESS" == "on" ]] && info "  - Enable Proxy Protocol on Hetzner LB for ports 80/443 (if not done)"
[[ "$INSTALL_CERTMGR" == "on" ]] && info "  - Verify ClusterIssuers: kubectl get clusterissuer"
[[ "$INSTALL_MONITORING" == "on" ]] && info "  - Access Grafana: https://${GRAFANA_HOST}"
[[ "$INSTALL_RANCHER" == "on" ]] && info "  - Access Rancher: https://${RANCHER_HOST}"
info "  - Deploy customer namespaces with network policies"
info "  - Switch Grafana to letsencrypt-prod when ready"

# Save credentials to file
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
