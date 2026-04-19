# shellcheck shell=bash
# =============================================================================
# 74-monitoring.sh — kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

KUBE_PROM_STACK_VERSION="${KUBE_PROM_STACK_VERSION:-69.3.0}"

applies_monitoring() { [[ "$(state_get STEP_rke2_service_COMPLETED)" == "yes" ]]; }

detect_monitoring() { return 0; }

configure_monitoring() {
    if ! ask_yesno "Install monitoring (Prometheus + Grafana + Alertmanager)?" "y"; then
        state_set PLATFORM_MONITORING no
        return 0
    fi
    state_set PLATFORM_MONITORING yes

    local cur_pw
    cur_pw="$(state_get PLATFORM_GRAFANA_PASSWORD)"
    if [[ -z "$cur_pw" ]]; then
        info "Grafana admin password (leave blank to auto-generate):"
        ask_password "Password" 0
        if [[ -z "$REPLY" ]]; then
            cur_pw="$(openssl rand -base64 16)"
            info "Auto-generated: $cur_pw"
        else
            cur_pw="$REPLY"
        fi
        state_set PLATFORM_GRAFANA_PASSWORD "$cur_pw"
    fi

    ask_input "Grafana hostname" \
        "$(state_get PLATFORM_GRAFANA_HOST "grafana.$(state_get PLATFORM_CERT_DOMAIN yourdomain.com)")"
    state_set PLATFORM_GRAFANA_HOST "$REPLY"

    if [[ "$(state_get PLATFORM_CERTMGR)" == yes ]]; then
        local idx=1
        [[ "$(state_get PLATFORM_GRAFANA_ISSUER)" == "letsencrypt-prod" ]] && idx=2
        ask_choice "TLS issuer for Grafana" "$idx" \
            "letsencrypt-staging|Test first" \
            "letsencrypt-prod|Production cert"
        if [[ "$REPLY" == "1" ]]; then
            state_set PLATFORM_GRAFANA_ISSUER letsencrypt-staging
        else
            state_set PLATFORM_GRAFANA_ISSUER letsencrypt-prod
        fi
    fi

    ask_input "Prometheus retention" "$(state_get PLATFORM_PROM_RETENTION 30d)"
    state_set PLATFORM_PROM_RETENTION "$REPLY"
    ask_input "Prometheus storage"   "$(state_get PLATFORM_PROM_STORAGE 50Gi)"
    state_set PLATFORM_PROM_STORAGE "$REPLY"
    ask_input "Alertmanager storage" "$(state_get PLATFORM_AM_STORAGE 5Gi)"
    state_set PLATFORM_AM_STORAGE "$REPLY"
}

check_monitoring() {
    [[ "$(state_get PLATFORM_MONITORING no)" == yes ]] || return 0
    helm status -n monitoring monitoring >/dev/null 2>&1
}

run_monitoring() {
    [[ "$(state_get PLATFORM_MONITORING)" == yes ]] || { log "monitoring disabled."; return 0; }

    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update prometheus-community

    local tmp grafana_host grafana_issuer
    tmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN
    grafana_host="$(state_get PLATFORM_GRAFANA_HOST)"
    grafana_issuer="$(state_get PLATFORM_GRAFANA_ISSUER)"

    local grafana_ingress=""
    if [[ -n "$grafana_issuer" && -n "$grafana_host" ]]; then
        grafana_ingress=$'\n  ingress:\n    enabled: true\n    ingressClassName: nginx\n    annotations:\n      cert-manager.io/cluster-issuer: "'"$grafana_issuer"$'"\n    hosts:\n      - '"$grafana_host"$'\n    tls:\n      - secretName: grafana-tls\n        hosts:\n          - '"$grafana_host"
    fi

    # Grafana sidecar watches for ConfigMaps with the grafana_datasource=1
    # label and adds them as datasources at runtime. 75-logging drops such a
    # ConfigMap for Loki if logging is installed — no ordering coupling here.
    local grafana_sidecar=$'\n  sidecar:\n    datasources:\n      enabled: true\n      label: grafana_datasource\n      labelValue: "1"\n      searchNamespace: ALL'

    cat > "$tmp" <<EOF
prometheus:
  prometheusSpec:
    retention: $(state_get PLATFORM_PROM_RETENTION)
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: $(state_get PLATFORM_PROM_STORAGE)
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
              storage: $(state_get PLATFORM_AM_STORAGE)
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        memory: 128Mi

grafana:
  adminPassword: "$(state_get PLATFORM_GRAFANA_PASSWORD)"
  persistence:
    enabled: true
    storageClassName: local-path
    size: 10Gi${grafana_ingress}${grafana_sidecar}
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      memory: 256Mi

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
        --namespace monitoring --create-namespace \
        --version "$KUBE_PROM_STACK_VERSION" \
        -f "$tmp"
    log "Monitoring stack installed"
    log "Grafana: https://${grafana_host} (admin / $(state_get PLATFORM_GRAFANA_PASSWORD))"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_monitoring || exit 0
    export PATH="$PATH:/var/lib/rancher/rke2/bin"
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    configure_monitoring
    check_monitoring && { log "Already installed; skipping."; exit 0; }
    run_monitoring
    check_monitoring || { err "monitoring verification failed"; exit 1; }
fi
