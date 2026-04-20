# shellcheck shell=bash
# =============================================================================
# 18-tailscale.sh — Optional Tailscale mesh VPN (installs early on purpose)
# =============================================================================
#
# Deliberately runs BEFORE 24-ssh-harden and 25-firewall so those modules can
# offer tailnet-aware options conditional on TAILSCALE_ENABLED=yes:
#   - 24-ssh-harden may enable Tailscale SSH (identity+ACL auth on the tailnet
#     IP, as an alternative to sshd for tailnet connections).
#   - 25-firewall may restrict the SSH allow rule to tailscale0 (lockdown mode)
#     with a console-recovery warning.
#
# This module is strictly about establishing the mesh VPN: `tailscale up`, and
# nothing else. No SSH decisions here, no UFW changes — 25-firewall owns UFW
# and will trust tailscale0 itself when it sees TAILSCALE_ENABLED=yes.
#
# Ordering note: needs network connectivity to install and auth. That's fine
# at position 18 — 15-networks doesn't gate connectivity, it only records
# interface/CIDR state. DHCP from cloud-init is already up by then.
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
    info "Installing now lets 24-ssh-harden and 25-firewall offer tailnet options."
    if ! ask_yesno "Install Tailscale VPN?" "n"; then
        state_set TAILSCALE_ENABLED no
        state_mark_skipped tailscale
        return 0
    fi
    state_set TAILSCALE_ENABLED yes
}

check_tailscale() {
    command -v tailscale >/dev/null 2>&1
}

verify_tailscale() {
    command -v tailscale >/dev/null 2>&1 || return 1
    systemctl is-active tailscaled >/dev/null 2>&1 || return 1
    tailscale status >/dev/null 2>&1 || return 1
}

run_tailscale() {
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up
    log "Tailscale connected (tailnet IP: $(tailscale ip -4 2>/dev/null | head -n1))"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_tailscale
    configure_tailscale
    state_skipped tailscale && exit 0
    check_tailscale && { log "Already installed."; }
    run_tailscale
    verify_tailscale || { err "Tailscale verification failed"; exit 1; }
fi
