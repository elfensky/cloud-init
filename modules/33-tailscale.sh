# shellcheck shell=bash
# =============================================================================
# 33-tailscale.sh — Optional Tailscale mesh VPN (+ Tailscale SSH, + SSH lockdown)
# =============================================================================
#
# Three composable layers, controlled by two sub-questions after the top-level
# install gate:
#
#   1. VPN only:         tailscale up           → tailnet + trust tailscale0 in UFW
#   2. + Tailscale SSH:  tailscale up --ssh     → tailscaled serves port 22 on the
#                                                 tailnet IP using identity ACLs;
#                                                 openssh on the public interface
#                                                 is untouched (both coexist).
#   3. + SSH lockdown:   rewrite UFW so port 22 is only allowed on tailscale0 —
#                        the public interface drops SSH. Load-bearing: pauses for
#                        a second-terminal tailnet-SSH verify before removing the
#                        public allow (same safety pattern as 24-ssh-harden).
#
# Why the lockdown lives here and not in 25-firewall: the decision requires
# `tailscale up` to have succeeded (interface must exist, we want to pause for a
# live verification). 25 runs before 33 and can't know the answer in advance.
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
    if ! ask_yesno "Install Tailscale VPN?" "n"; then
        state_set TAILSCALE_ENABLED no
        state_mark_skipped tailscale
        return 0
    fi
    state_set TAILSCALE_ENABLED yes

    info "Tailscale SSH replaces public-key auth with tailnet identity + ACLs"
    info "on the tailnet IP only (https://tailscale.com/kb/1193/tailscale-ssh)."
    info "Your hardened sshd on the public interface is untouched — both coexist."
    if ask_yesno "Enable Tailscale SSH (identity-based auth)?" "y"; then
        state_set TAILSCALE_SSH yes
    else
        state_set TAILSCALE_SSH no
    fi

    local ssh_port
    ssh_port="$(state_get SSH_PORT 22)"
    info "Lockdown moves the public SSH firewall rule onto tailscale0 — port"
    info "${ssh_port} becomes unreachable from the internet, reachable only when"
    info "connected to your tailnet. Recovery requires console/serial if Tailscale"
    info "breaks, so this pauses for a live tailnet-SSH verify before applying."
    if ask_yesno "Restrict SSH to the Tailscale network only?" "n"; then
        state_set TAILSCALE_SSH_LOCKDOWN yes
    else
        state_set TAILSCALE_SSH_LOCKDOWN no
    fi
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

    local up_args=()
    [[ "$(state_get TAILSCALE_SSH no)" == yes ]] && up_args+=(--ssh)
    tailscale up "${up_args[@]}"

    ufw allow in on tailscale0 comment 'Tailscale' 2>/dev/null || true

    if [[ "$(state_get TAILSCALE_SSH_LOCKDOWN no)" == yes ]]; then
        lockdown_public_ssh
    fi

    log "Tailscale installed"
}

# Move the public SSH allow onto tailscale0. Must run AFTER `tailscale up`
# succeeds — we verify the tailnet interface is live before removing the
# public path, and pause for an operator-driven secondary-terminal check.
lockdown_public_ssh() {
    local ssh_port pub_if user tailnet_ip
    ssh_port="$(state_get SSH_PORT 22)"
    pub_if="$(state_get NET_PUBLIC_IFACE)"
    user="$(state_get USER_NAME)"

    if ! tailnet_ip="$(tailscale ip -4 2>/dev/null | head -n1)" || [[ -z "$tailnet_ip" ]]; then
        err "Tailscale is not connected (no tailnet IP) — refusing to remove public SSH rule."
        return 1
    fi

    echo ""
    warn "═══════════════════════════════════════════════════════════════"
    warn "  Verify SSH over Tailscale in ANOTHER terminal BEFORE lockdown:"
    warn "    ssh -p ${ssh_port} ${user:-<user>}@${tailnet_ip}"
    if [[ "$(state_get TAILSCALE_SSH no)" == yes ]]; then
        warn "  Or using Tailscale SSH (no keys needed):"
        warn "    tailscale ssh ${user:-<user>}@${tailnet_ip}"
    fi
    warn "═══════════════════════════════════════════════════════════════"
    echo ""
    if ! ask_yesno "Have you verified SSH over Tailscale in another terminal?" "n"; then
        warn "Lockdown aborted — public SSH rule unchanged."
        return 0
    fi

    if [[ -n "$pub_if" ]]; then
        ufw delete allow in on "$pub_if" to any port "$ssh_port" proto tcp 2>/dev/null || true
    else
        ufw delete allow "${ssh_port}/tcp" 2>/dev/null || true
    fi
    ufw allow in on tailscale0 to any port "$ssh_port" proto tcp comment 'SSH (tailnet)'
    log "Public SSH removed — port ${ssh_port} reachable only over Tailscale."
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
