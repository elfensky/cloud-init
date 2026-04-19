# shellcheck shell=bash
# =============================================================================
# 64-rke2-wireguard.sh — Pod-to-pod encryption: CNI-specific HelmChartConfig
# =============================================================================
#
# Applies ONLY on the bootstrap node when WIREGUARD=yes. Writes into
# /var/lib/rancher/rke2/server/manifests/ so the config is applied when the
# server first boots.
#
# Calico is handled in 65-rke2-post.sh because it needs a kubectl patch
# AFTER all nodes join (cluster-wide setting).
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_rke2_wireguard() {
    [[ "$(state_get STEP_rke2_SELECTED)" == "yes" ]] \
        && [[ "$(state_get RKE2_ROLE)" == "bootstrap" ]] \
        && [[ "$(state_get RKE2_WIREGUARD)" == "yes" ]]
}

detect_rke2_wireguard()   { return 0; }
configure_rke2_wireguard() {
    info "Writes a HelmChartConfig for Cilium/Canal WireGuard (bootstrap only)."
    info "Calico handles WireGuard via kubectl patch after all nodes join — see 65."
    if ! ask_yesno "Write the WireGuard HelmChartConfig manifest?" "y"; then
        state_mark_skipped rke2_wireguard
        return 0
    fi
}

check_rke2_wireguard() {
    local cni manifest
    cni="$(state_get RKE2_CNI)"
    case "$cni" in
        cilium) manifest=/var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml ;;
        canal)  manifest=/var/lib/rancher/rke2/server/manifests/rke2-canal-config.yaml ;;
        *) return 0 ;;  # Calico: no manifest to check
    esac
    [[ -f "$manifest" ]]
}

run_rke2_wireguard() {
    local manifests=/var/lib/rancher/rke2/server/manifests
    mkdir -p "$manifests"
    chmod 700 "$manifests"

    case "$(state_get RKE2_CNI)" in
        cilium)
            cat > "${manifests}/rke2-cilium-config.yaml" <<'EOF'
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
EOF
            log "Cilium WireGuard HelmChartConfig written"
            ;;
        canal)
            cat > "${manifests}/rke2-canal-config.yaml" <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-canal
  namespace: kube-system
spec:
  valuesContent: |-
    flannel:
      backend: "wireguard"
EOF
            log "Canal WireGuard HelmChartConfig written"
            warn "Canal WireGuard is less mature; monitor stability."
            ;;
        calico)
            info "Calico WireGuard is enabled post-install (65-rke2-post.sh)."
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_rke2_wireguard || exit 0
    check_rke2_wireguard && { log "Already written; skipping."; exit 0; }
    run_rke2_wireguard
    check_rke2_wireguard || { err "WireGuard manifest verification failed"; exit 1; }
fi
