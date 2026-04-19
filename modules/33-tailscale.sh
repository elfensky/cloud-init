# shellcheck shell=bash
# =============================================================================
# 33-tailscale.sh — Optional Tailscale mesh VPN
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_tailscale() { return 0; }
detect_tailscale()  { return 0; }

configure_tailscale() {
    info "Zero-config mesh VPN over WireGuard; requires a Tailscale account."
    info "Optional — skip if this host doesn't need private access from laptops/phones."
    if ask_yesno "Install Tailscale VPN?" "n"; then
        state_set TAILSCALE_ENABLED yes
    else
        state_set TAILSCALE_ENABLED no
    fi
}

check_tailscale() {
    [[ "$(state_get TAILSCALE_ENABLED)" == yes ]] || return 0
    command -v tailscale >/dev/null 2>&1
}

run_tailscale() {
    [[ "$(state_get TAILSCALE_ENABLED)" == yes ]] || { log "Tailscale disabled."; return 0; }
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up
    ufw allow in on tailscale0 comment 'Tailscale' 2>/dev/null || true
    log "Tailscale installed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    configure_tailscale
    check_tailscale && { log "Already installed; skipping."; exit 0; }
    run_tailscale
    check_tailscale || { err "Tailscale verification failed"; exit 1; }
fi
