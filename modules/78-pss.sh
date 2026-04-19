# shellcheck shell=bash
# =============================================================================
# 78-pss.sh — Pod Security Standards labels on platform namespaces
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_pss() { [[ "$(state_get PROFILE)" == k8s ]]; }

detect_pss()   { return 0; }
configure_pss(){ return 0; }
check_pss()    { return 1; }

run_pss() {
    local ns
    for ns in monitoring ingress-nginx cert-manager cattle-system crowdsec; do
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            kubectl label namespace "$ns" \
                pod-security.kubernetes.io/enforce=baseline \
                pod-security.kubernetes.io/warn=restricted \
                --overwrite >/dev/null
        fi
    done
    log "Pod Security Standards labels applied"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_pss || exit 0
    export PATH="$PATH:/var/lib/rancher/rke2/bin"
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    run_pss
fi
