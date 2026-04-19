# shellcheck shell=bash
# =============================================================================
# 29-unattended.sh — unattended-upgrades for automatic security patching
# =============================================================================
#
# K8s profile: no auto-reboot (use kured for coordinated node reboots).
# docker/bare:  reboot at 04:00 — patches that require a reboot stay pending
# indefinitely otherwise, leaving the host running a vulnerable kernel.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_unattended() { return 0; }
detect_unattended()  { return 0; }

configure_unattended() {
    if ask_yesno "Enable unattended security upgrades?" "y"; then
        state_set UNATTENDED_ENABLED yes
    else
        state_set UNATTENDED_ENABLED no
    fi
}

check_unattended() {
    [[ "$(state_get UNATTENDED_ENABLED no)" == yes ]] || return 0
    systemctl is-active --quiet unattended-upgrades && [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]]
}

run_unattended() {
    [[ "$(state_get UNATTENDED_ENABLED)" == yes ]] || { log "Unattended upgrades disabled."; return 0; }

    apt-get install -y -qq unattended-upgrades 2>/dev/null

    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

    local profile reboot_block
    profile="$(state_get PROFILE)"
    if [[ "$profile" == "k8s" ]]; then
        reboot_block='// K8s: auto-reboot disabled — use kured for coordinated node reboots
Unattended-Upgrade::Automatic-Reboot "false";'
    else
        reboot_block='Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";'
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
    if [[ "$profile" == "k8s" ]]; then
        log "Unattended upgrades configured (security patches, auto-reboot disabled)"
    else
        log "Unattended upgrades configured (security patches, reboot at 04:00)"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    configure_unattended
    check_unattended && { log "Already configured; skipping."; exit 0; }
    run_unattended
fi
