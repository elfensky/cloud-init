# shellcheck shell=bash
# =============================================================================
# 65-rke2-post.sh — kubectl profile script + Calico WireGuard convenience
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_rke2_post() { [[ "$(state_get PROFILE)" == k8s ]]; }

detect_rke2_post()   { return 0; }
configure_rke2_post(){ return 0; }

check_rke2_post() {
    [[ "$(state_get RKE2_ROLE)" == "worker" ]] && return 0  # nothing to post on workers
    [[ -f /etc/profile.d/rke2.sh ]]
}

run_rke2_post() {
    local role
    role="$(state_get RKE2_ROLE)"

    if [[ "$role" != "worker" ]]; then
        cat > /etc/profile.d/rke2.sh <<'EOF'
export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
EOF
        chmod 600 /etc/rancher/rke2/rke2.yaml 2>/dev/null || true
        log "kubectl environment registered in /etc/profile.d/rke2.sh"
    fi

    # Calico WireGuard helper, bootstrap only.
    if [[ "$role" == "bootstrap" \
          && "$(state_get RKE2_WIREGUARD)" == "yes" \
          && "$(state_get RKE2_CNI)" == "calico" ]]; then
        cat > /usr/local/bin/rke2-enable-wireguard <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin
echo "Enabling Calico WireGuard encryption..."
kubectl patch felixconfiguration default --type=merge \
  -p '{"spec":{"wireguardEnabled":true}}'
echo "Done. Verify:"
echo "  kubectl get felixconfiguration default -o jsonpath='{.spec.wireguardEnabled}'"
EOF
        chmod 700 /usr/local/bin/rke2-enable-wireguard
        echo ""
        warn "═══════════════════════════════════════════════════════════════"
        warn "  CALICO WIREGUARD — AFTER all nodes join, run:"
        warn "    rke2-enable-wireguard"
        warn "  Applying early breaks nodes without WireGuard kernel modules."
        warn "═══════════════════════════════════════════════════════════════"
        echo ""
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_rke2_post || exit 0
    run_rke2_post
fi
