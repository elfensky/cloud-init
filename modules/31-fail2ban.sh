# shellcheck shell=bash
# =============================================================================
# 31-fail2ban.sh — Fail2ban + UFW action, private-net-aware ignoreip
# =============================================================================
#
# bantime=1h, maxretry=3, findtime=10m. banaction=ufw so bans integrate with
# the firewall instead of a parallel iptables ruleset. ignoreip includes
# the loopback network and (if present) NET_PRIVATE_CIDR so intra-server
# rsync/ssh probes don't trigger bans.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_fail2ban() { [[ "$(state_get SECURITY_TOOL)" == fail2ban ]]; }

detect_fail2ban()   { return 0; }
configure_fail2ban(){ return 0; }

check_fail2ban() {
    [[ -f /etc/fail2ban/jail.local ]] && systemctl is-active --quiet fail2ban
}

run_fail2ban() {
    apt-get install -y -qq fail2ban 2>/dev/null

    local ssh_port priv_cidr ignore
    ssh_port="$(state_get SSH_PORT 22)"
    priv_cidr="$(state_get NET_PRIVATE_CIDR)"
    ignore="127.0.0.1/8 ::1"
    [[ -n "$priv_cidr" ]] && ignore+=" $priv_cidr"

    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
banaction = ufw
ignoreip = ${ignore}

[sshd]
enabled  = true
port     = ${ssh_port}
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 3600
EOF

    systemctl enable fail2ban --now 2>/dev/null || true
    systemctl restart fail2ban
    log "Fail2ban active (SSH: 3 retries, 1h ban; ignoring: ${ignore})"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_fail2ban || { info "Not selected; skipping."; exit 0; }
    check_fail2ban && { log "Already configured; skipping."; exit 0; }
    run_fail2ban
fi
