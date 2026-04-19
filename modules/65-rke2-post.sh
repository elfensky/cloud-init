# shellcheck shell=bash
# =============================================================================
# 65-rke2-post.sh — /etc/profile.d/rke2.sh + Calico WireGuard helper script
# =============================================================================
#
# Drops a shell profile snippet so any user's interactive login sees kubectl
# on PATH and KUBECONFIG pointed at the RKE2 kubeconfig. Skipped on workers
# (no kubeconfig locally).
#
# For Calico + WireGuard, installs /usr/local/bin/rke2-enable-wireguard as a
# convenience wrapper around the cluster-wide kubectl patch. The operator
# must run it AFTER all nodes have joined — applying before then breaks
# pods on nodes that haven't loaded the WireGuard kernel module.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_rke2_post() { [[ "$(state_get STEP_rke2_SELECTED)" == "yes" ]]; }

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
    check_rke2_post || { err "RKE2 post-install verification failed"; exit 1; }
fi
