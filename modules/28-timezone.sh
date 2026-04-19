# shellcheck shell=bash
# =============================================================================
# 28-timezone.sh — System timezone + NTP (systemd-timesyncd)
# =============================================================================
#
# Auto-detects the current system timezone (or tries a best-effort guess from
# the public IP geolocation via `timedatectl`, which consults the kernel's
# /etc/timezone first). Operator can accept the detected value or override
# with any IANA zone name like "Europe/Brussels" or "America/Los_Angeles".
# UTC is recommended for servers (keeps logs unambiguous, no DST bugs) —
# wizard default is still UTC if nothing else is detected.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_timezone() { return 0; }

detect_timezone() {
    # If state already has a choice (from a previous run / --answers seed),
    # keep it. Otherwise auto-detect from the running system.
    [[ -n "$(state_get TIMEZONE)" ]] && return 0
    local current
    current="$(timedatectl show --value -p Timezone 2>/dev/null)"
    # timedatectl returns "Etc/UTC" or similar on a fresh Ubuntu; normalise
    # to plain UTC for readability and pass-through otherwise.
    [[ "$current" == "Etc/UTC" ]] && current="UTC"
    state_set TIMEZONE "${current:-UTC}"
}

configure_timezone() {
    info "Sets system timezone and enables systemd-timesyncd for NTP."
    info "UTC is recommended for servers; local zones are supported."
    while true; do
        ask_input "Timezone (IANA name, e.g. UTC, Europe/Brussels, America/Los_Angeles)" \
            "$(state_get TIMEZONE UTC)"
        # Validate against the kernel's list of known zones.
        if timedatectl list-timezones 2>/dev/null | grep -qx "$REPLY"; then
            state_set TIMEZONE "$REPLY"
            break
        fi
        err "Unknown timezone: $REPLY"
        info "List available zones: timedatectl list-timezones | less"
    done
}

check_timezone() {
    local want have
    want="$(state_get TIMEZONE UTC)"
    have="$(timedatectl show --value -p Timezone 2>/dev/null)"
    # Treat Etc/UTC as UTC for the equality check.
    [[ "$have" == "Etc/UTC" ]] && have="UTC"
    [[ "$want" == "$have" ]] && systemctl is-active --quiet systemd-timesyncd
}

verify_timezone() { check_timezone; }

run_timezone() {
    local tz
    tz="$(state_get TIMEZONE UTC)"
    timedatectl set-timezone "$tz"
    systemctl enable systemd-timesyncd --now 2>/dev/null || true
    log "Timezone ${tz}, NTP (systemd-timesyncd) enabled"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_timezone
    configure_timezone
    check_timezone && { log "Timezone + NTP already set; skipping."; exit 0; }
    run_timezone
    check_timezone || { err "Timezone verification failed"; exit 1; }
fi
