# shellcheck shell=bash
# =============================================================================
# 75-logging.sh — Loki (SingleBinary) + Promtail DaemonSet
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

LOKI_VERSION="${LOKI_VERSION:-6.25.0}"
PROMTAIL_VERSION="${PROMTAIL_VERSION:-6.16.6}"

applies_logging() { [[ "$(state_get STEP_rke2_service_COMPLETED)" == "yes" ]]; }

detect_logging() { return 0; }

configure_logging() {
    if ! ask_yesno "Install logging (Loki + Promtail)?" "y"; then
        state_set PLATFORM_LOGGING no
        return 0
    fi
    state_set PLATFORM_LOGGING yes
    ask_input "Loki retention (h)"  "$(state_get PLATFORM_LOKI_RETENTION 336h)"
    state_set PLATFORM_LOKI_RETENTION "$REPLY"
    ask_input "Loki storage size"   "$(state_get PLATFORM_LOKI_STORAGE 50Gi)"
    state_set PLATFORM_LOKI_STORAGE "$REPLY"
}

check_logging() {
    [[ "$(state_get PLATFORM_LOGGING no)" == yes ]] || return 0
    helm status -n monitoring loki >/dev/null 2>&1 \
        && helm status -n monitoring promtail >/dev/null 2>&1
}

run_logging() {
    [[ "$(state_get PLATFORM_LOGGING)" == yes ]] || { log "logging disabled."; return 0; }

    helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
    helm repo update grafana

    local loki_tmp promtail_tmp
    loki_tmp="$(mktemp)"
    promtail_tmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$loki_tmp' '$promtail_tmp'" RETURN

    cat > "$loki_tmp" <<EOF
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
    retention_period: $(state_get PLATFORM_LOKI_RETENTION)
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
    size: $(state_get PLATFORM_LOKI_STORAGE)
  gateway:
    enabled: false
promtail:
  enabled: false
EOF

    helm upgrade --install loki grafana/loki \
        --namespace monitoring \
        --version "$LOKI_VERSION" \
        -f "$loki_tmp"

    cat > "$promtail_tmp" <<'EOF'
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
        -f "$promtail_tmp"

    log "Loki + Promtail installed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_logging || exit 0
    export PATH="$PATH:/var/lib/rancher/rke2/bin"
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    configure_logging
    check_logging && { log "Already installed; skipping."; exit 0; }
    run_logging
fi
