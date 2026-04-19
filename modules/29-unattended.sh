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

    # Optional email for the unattended-upgrades MailReport. If set, we
    # also offer to install msmtp-mta below so delivery actually works —
    # the directive alone doesn't include a mail relay.
    ask_input "Email for upgrade reports (blank to skip)" \
        "$(state_get UNATTENDED_MAIL)"
    state_set UNATTENDED_MAIL "$REPLY"

    # MTA setup: only relevant when an email was provided. unattended-upgrades
    # invokes /usr/sbin/sendmail, which msmtp-mta registers via the
    # update-alternatives mechanism — no config change needed on their side.
    state_set UNATTENDED_MTA_SETUP no
    if [[ -n "$(state_get UNATTENDED_MAIL)" ]]; then
        info "Without a local MTA the email address above is dropped silently."
        info "msmtp-mta is a lightweight relay: one config file, registers as sendmail."
        if ask_yesno "Configure a local MTA (msmtp) now?" "y"; then
            local existing_mta=""
            if systemctl is-active --quiet postfix 2>/dev/null; then
                existing_mta="postfix"
            elif systemctl is-active --quiet exim4 2>/dev/null; then
                existing_mta="exim4"
            elif [[ -L /usr/sbin/sendmail ]] \
                 && [[ "$(readlink -f /usr/sbin/sendmail 2>/dev/null)" != *msmtp* ]]; then
                existing_mta="$(readlink -f /usr/sbin/sendmail)"
            fi
            if [[ -n "$existing_mta" ]]; then
                warn "Existing MTA detected (${existing_mta}) — leaving it alone."
            else
                state_set UNATTENDED_MTA_SETUP yes
                ask_input "SMTP relay host (e.g. smtp.gmail.com)" \
                    "$(state_get UNATTENDED_MTA_HOST)"
                state_set UNATTENDED_MTA_HOST "$REPLY"
                ask_input "SMTP port (587 STARTTLS; 465 TLS-wrapped)" \
                    "$(state_get UNATTENDED_MTA_PORT 587)" '^[0-9]+$'
                state_set UNATTENDED_MTA_PORT "$REPLY"
                ask_input "SMTP username (usually full email)" \
                    "$(state_get UNATTENDED_MTA_USER)"
                state_set UNATTENDED_MTA_USER "$REPLY"
                ask_password "SMTP password (app password for Gmail/O365)" 1
                state_set UNATTENDED_MTA_PASSWORD "$REPLY"
                ask_input "From address (must match what the relay accepts)" \
                    "$(state_get UNATTENDED_MTA_FROM "$(state_get UNATTENDED_MTA_USER)")"
                state_set UNATTENDED_MTA_FROM "$REPLY"
            fi
        fi
    fi

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

verify_unattended() {
    check_unattended || return 1
    if [[ "$(state_get UNATTENDED_MTA_SETUP no)" == yes ]]; then
        [[ -f /etc/msmtprc ]] || return 1
        [[ "$(stat -c %a /etc/msmtprc)" == "600" ]] || return 1
        command -v msmtp >/dev/null 2>&1 || return 1
    fi
    return 0
}

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
    else
        log "Unattended upgrades enabled (auto-reboot=$(state_get UNATTENDED_AUTO_REBOOT); no mail)"
    fi

    # MTA setup — only when operator opted in during configure_unattended.
    # msmtp-mta registers as /usr/sbin/sendmail via update-alternatives, so
    # unattended-upgrades (and any cron/systemd mail) route through it with
    # no further config on the consumer side.
    if [[ "$(state_get UNATTENDED_MTA_SETUP no)" == yes ]]; then
        apt-get install -y -qq msmtp msmtp-mta mailutils 2>/dev/null

        local port tls_starttls
        port="$(state_get UNATTENDED_MTA_PORT)"
        # 465 = TLS-wrapped (tls_starttls off); 587 and anything else = STARTTLS.
        if [[ "$port" == "465" ]]; then tls_starttls="off"; else tls_starttls="on"; fi

        cat > /etc/msmtprc <<EOF
# Generated by modules/29-unattended.sh on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
defaults
auth           on
tls            on
tls_starttls   ${tls_starttls}
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        default
host           $(state_get UNATTENDED_MTA_HOST)
port           ${port}
from           $(state_get UNATTENDED_MTA_FROM)
user           $(state_get UNATTENDED_MTA_USER)
password       $(state_get UNATTENDED_MTA_PASSWORD)
EOF
        chmod 600 /etc/msmtprc
        chown root:root /etc/msmtprc

        touch /var/log/msmtp.log
        chmod 600 /var/log/msmtp.log

        # /etc/aliases: map root → operator so cron/timer mail also lands.
        # Match on ^root: so any existing alias (even with different target)
        # wins — operator-managed state takes precedence over our default.
        touch /etc/aliases
        if ! grep -qE "^root:" /etc/aliases; then
            printf 'root: %s\n' "$mail_addr" >> /etc/aliases
        fi
        newaliases 2>/dev/null || true

        log "msmtp configured (host=$(state_get UNATTENDED_MTA_HOST):${port}, from=$(state_get UNATTENDED_MTA_FROM))"
        log "Test delivery:  echo test | mail -s 'wizard mta test' ${mail_addr}"
    elif [[ -n "$mail_addr" ]]; then
        warn "Email set but no MTA configured — reports will be dropped silently."
        warn "Install later with: apt install msmtp-mta && edit /etc/msmtprc"
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
