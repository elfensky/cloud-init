# shellcheck shell=bash
# =============================================================================
# 60-rke2-preflight.sh — K8s readiness checks for RKE2 install
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_rke2_preflight() { [[ "$(state_get PROFILE)" == k8s ]]; }

detect_rke2_preflight()   { return 0; }
configure_rke2_preflight(){ return 0; }

check_rke2_preflight() { return 1; }  # Always run — cheap and informative.

run_rke2_preflight() {
    # ip_forward=1 is required for pod networking.
    if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ]]; then
        err "net.ipv4.ip_forward is not 1. Re-run the OS phase (sysctl) first."
        exit 1
    fi

    if [[ -z "$(state_get NET_PRIVATE_IFACE)" ]]; then
        warn "No private interface detected. Single-network K8s clusters work but"
        warn "mixing public and private traffic is usually not what you want."
    fi

    if systemctl is-active --quiet rke2-server 2>/dev/null \
        || systemctl is-active --quiet rke2-agent 2>/dev/null; then
        warn "RKE2 is already running on this node."
        if ! ask_yesno "Continue (will reconfigure)?" "n"; then
            exit 0
        fi
    fi
    log "RKE2 preflight ok"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_rke2_preflight || exit 0
    run_rke2_preflight
fi
