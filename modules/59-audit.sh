# shellcheck shell=bash
# =============================================================================
# 59-audit.sh — auditd rules for K8s hosts (RKE2, identity, sudo, cron)
# =============================================================================
# Sits between OS hardening and RKE2 because its rationale is K8s-specific but
# the file it writes is host-level.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_audit() { [[ "$(state_get PROFILE)" == k8s ]]; }

detect_audit() { return 0; }
configure_audit() { return 0; }

check_audit() {
    [[ -f /etc/audit/rules.d/rke2.rules ]] && systemctl is-active --quiet auditd
}

run_audit() {
    cat > /etc/audit/rules.d/rke2.rules <<'EOF'
# RKE2 binaries — detect unauthorized execution or replacement.
-w /usr/local/bin/rke2 -p x -k rke2
-w /var/lib/rancher/rke2/bin/ -p x -k rke2-bins

# RKE2/Rancher config and data — detect cluster config modifications.
-w /etc/rancher/ -p wa -k rancher-config
-w /var/lib/rancher/ -p wa -k rancher-data

# Identity files — detect account creation/deletion/modification.
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity

# Sudoers — detect privilege-escalation attempts via config changes.
-w /etc/sudoers -p wa -k sudo-changes
-w /etc/sudoers.d/ -p wa -k sudo-changes

# Home directories — detect authorized_keys modifications.
-w /home/ -p wa -k home-changes

# Cron — detect persistence via scheduled-task tampering.
-w /etc/crontab -p wa -k cron
-w /etc/cron.d/ -p wa -k cron
EOF

    systemctl enable auditd --now 2>/dev/null || true
    augenrules --load 2>/dev/null || systemctl restart auditd 2>/dev/null || true
    log "Audit rules installed (RKE2, identity, sudo, cron)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_audit || exit 0
    check_audit && { log "Already configured; skipping."; exit 0; }
    run_audit
fi
