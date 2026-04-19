# shellcheck shell=bash
# =============================================================================
# 79-netpol.sh — Default-deny ingress + intra-monitoring + Grafana-from-ingress
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_netpol() {
    [[ "$(state_get PROFILE)" == k8s ]] \
        && [[ "$(state_get PLATFORM_MONITORING)" == yes || "$(state_get PLATFORM_LOGGING)" == yes ]]
}

detect_netpol() { return 0; }
configure_netpol() { return 0; }

check_netpol() {
    kubectl get networkpolicy -n monitoring default-deny-ingress >/dev/null 2>&1
}

run_netpol() {
    kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: monitoring
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
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
EOF
    log "Network policies applied (monitoring namespace)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_netpol || exit 0
    export PATH="$PATH:/var/lib/rancher/rke2/bin"
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    check_netpol && { log "Already applied; skipping."; exit 0; }
    run_netpol
fi
