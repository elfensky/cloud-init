# shellcheck shell=bash
# =============================================================================
# 29-unattended.sh — unattended-upgrades for automatic security patching
# =============================================================================
#
# Operator chooses whether to enable at all, and whether to auto-reboot at
# 04:00 UTC when a security update requires it. Default auto-reboot is OFF
# when RKE2 was selected earlier (K8s nodes need coordinated reboots via
# kured) and ON otherwise.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_unattended() { return 0; }
detect_unattended()  { return 0; }

configure_unattended() {
    if ! ask_yesno "Enable unattended security upgrades?" "y"; then
        state_mark_skipped unattended
        return 0
    fi

    # Reboot default: off when RKE2 was selected (use kured), on otherwise.
    local reboot_default="y"
    [[ "$(state_get STEP_rke2_SELECTED)" == "yes" ]] && reboot_default="n"

    if ask_yesno "Auto-reboot at 04:00 when a kernel update requires it?" "$reboot_default"; then
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
Unattended-Upgrade::SyslogEnable "true";
EOF

    systemctl enable --now unattended-upgrades
    log "Unattended upgrades enabled (auto-reboot=$(state_get UNATTENDED_AUTO_REBOOT))"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    configure_unattended
    state_skipped unattended && exit 0
    run_unattended
    verify_unattended || { err "unattended-upgrades verification failed"; exit 1; }
fi
