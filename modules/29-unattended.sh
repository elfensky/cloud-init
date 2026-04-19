# shellcheck shell=bash
# =============================================================================
# 29-unattended.sh — unattended-upgrades for automatic security patching
# =============================================================================
#
# Operator chooses whether to enable at all, and whether to auto-reboot at
# 04:00 UTC when a security update requires it. Auto-reboot default is "y"
# (uncoordinated reboots are fine for single-node VPS / Docker hosts); K8s
# operators should answer "n" when the wizard asks, because uncoordinated
# 04:00 reboots on a cluster node bypass kured's coordination.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_unattended() { return 0; }
detect_unattended()  { return 0; }

configure_unattended() {
    info "Daily apt security patching via unattended-upgrades."
    info "Security-only channel; feature updates stay manual."
    if ! ask_yesno "Enable unattended security upgrades?" "y"; then
        state_mark_skipped unattended
        return 0
    fi

    # Email for unattended-upgrades MailReport. Defaults to the MTA's
    # notification email (set in 19-mta) so operators who configured mail
    # earlier just hit Enter; they can still override per-concern here.
    # Delivery only actually works if 19-mta ran OR an external MTA exists.
    ask_input "Email for upgrade reports (blank to skip)" \
        "$(state_get UNATTENDED_MAIL "$(state_get MTA_NOTIFY_EMAIL)")"
    state_set UNATTENDED_MAIL "$REPLY"

    # 29 runs before 60-rke2-preflight, so we can't default off based on an
    # RKE2 selection that hasn't been made yet. Operators on K8s nodes must
    # answer "n" — documented in the prompt so it's hard to miss.
    info "Note: K8s (RKE2) nodes should answer 'n' below — use kured for"
    info "coordinated cluster reboots instead of 04:00 UTC kernel restarts."
    if ask_yesno "Auto-reboot at 04:00 when a kernel update requires it?" "y"; then
        state_set UNATTENDED_AUTO_REBOOT yes
    else
        state_set UNATTENDED_AUTO_REBOOT no
    fi
}

check_unattended() {
    [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]] \
        && systemctl is-active --quiet unattended-upgrades
}

verify_unattended() { check_unattended; }

run_unattended() {
    apt-get install -y -qq unattended-upgrades 2>/dev/null

    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

    local reboot_block
    if [[ "$(state_get UNATTENDED_AUTO_REBOOT no)" == "yes" ]]; then
        reboot_block='Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";'
    else
        reboot_block='// Auto-reboot disabled (use kured or manual reboots on K8s nodes)
Unattended-Upgrade::Automatic-Reboot "false";'
    fi

    local mail_block=""
    local mail_addr
    mail_addr="$(state_get UNATTENDED_MAIL)"
    if [[ -n "$mail_addr" ]]; then
        # MailReport "on-change" = only when something actually got upgraded
        # or an error occurred. Quieter than the default "always".
        mail_block="Unattended-Upgrade::Mail \"${mail_addr}\";
Unattended-Upgrade::MailReport \"on-change\";"
    fi

    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
${reboot_block}
${mail_block}
Unattended-Upgrade::SyslogEnable "true";
EOF

    systemctl enable --now unattended-upgrades
    if [[ -n "$mail_addr" ]]; then
        log "Unattended upgrades enabled (auto-reboot=$(state_get UNATTENDED_AUTO_REBOOT); mail→${mail_addr})"
        # Warn if an email was set but no sendmail is present — otherwise the
        # reports vanish into /dev/null without a hint. 19-mta is the normal
        # way to fix this; a pre-existing postfix/exim4 is also fine.
        if ! command -v sendmail >/dev/null 2>&1 && [[ ! -x /usr/sbin/sendmail ]]; then
            warn "No sendmail found — upgrade reports will be dropped silently."
            warn "Re-run 19-mta (sudo ./main.sh --redo mta) to set up msmtp."
        fi
    else
        log "Unattended upgrades enabled (auto-reboot=$(state_get UNATTENDED_AUTO_REBOOT); no mail)"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    configure_unattended
    state_skipped unattended && exit 0
    run_unattended
    verify_unattended || { err "unattended-upgrades verification failed"; exit 1; }
fi
