# shellcheck shell=bash
# =============================================================================
# 60-rke2-preflight.sh — Asks "Install RKE2?", runs readiness checks
# =============================================================================
#
# This is the RKE2 entry point. On 'yes' it:
#   1. Sets STEP_rke2_SELECTED=yes so downstream modules (61–65) apply.
#   2. Warns if no private interface (single-network K8s works but mixing
#      public+private traffic is usually a misconfiguration).
#   3. Warns if RKE2 is already running (reconfigure with operator consent).
#   4. Does NOT require ip_forward=1 up-front — 62-rke2-install writes the
#      full RKE2 sysctl file before the binary starts.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_rke2_preflight() { return 0; }

detect_rke2_preflight() { return 0; }

configure_rke2_preflight() {
    if ! ask_yesno "Install RKE2 (Kubernetes)?" "n"; then
        state_mark_skipped rke2_preflight
        state_set STEP_rke2_SELECTED no
        return 0
    fi
    state_set STEP_rke2_SELECTED yes
}

check_rke2_preflight() { return 1; }   # cheap; always rerun
verify_rke2_preflight() { return 0; }  # preflight is advisory only

run_rke2_preflight() {
    if [[ -z "$(state_get NET_PRIVATE_IFACE)" ]]; then
        warn "No private interface detected. Single-network K8s clusters work but"
        warn "mixing public and private traffic is usually not what you want."
    fi

    if systemctl is-active --quiet rke2-server 2>/dev/null \
        || systemctl is-active --quiet rke2-agent 2>/dev/null; then
        warn "RKE2 is already running on this node."
        if ! ask_yesno "Continue (will reconfigure)?" "n"; then
            state_mark_skipped rke2_preflight
            state_set STEP_rke2_SELECTED no
            return 0
        fi
    fi
    log "RKE2 preflight ok"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    configure_rke2_preflight
    state_skipped rke2_preflight && exit 0
    run_rke2_preflight
fi
