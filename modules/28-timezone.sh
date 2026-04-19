# shellcheck shell=bash
# =============================================================================
# 28-timezone.sh — Timezone UTC + NTP via systemd-timesyncd
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_timezone()  { return 0; }
detect_timezone()   { return 0; }
configure_timezone(){ return 0; }
check_timezone() {
    timedatectl show --value -p Timezone 2>/dev/null | grep -qx "UTC" \
        && systemctl is-active --quiet systemd-timesyncd
}

run_timezone() {
    timedatectl set-timezone UTC
    systemctl enable systemd-timesyncd --now 2>/dev/null || true
    log "Timezone UTC, NTP enabled"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    check_timezone && { log "Timezone + NTP already set; skipping."; exit 0; }
    run_timezone
    check_timezone || { err "Timezone verification failed"; exit 1; }
fi
