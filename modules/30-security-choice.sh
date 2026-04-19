# shellcheck shell=bash
# =============================================================================
# 30-security-choice.sh — Host-level intrusion tool: fail2ban XOR crowdsec
# =============================================================================
#
# Mutually exclusive. Writes SECURITY_TOOL state to gate 31/32.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_security_choice() { return 0; }

detect_security_choice() {
    if command -v cscli >/dev/null 2>&1 && systemctl is-active --quiet crowdsec; then
        state_set SECURITY_TOOL crowdsec
    elif systemctl is-active --quiet fail2ban; then
        state_set SECURITY_TOOL fail2ban
    fi
}

configure_security_choice() {
    local cur idx=1
    cur="$(state_get SECURITY_TOOL fail2ban)"
    [[ "$cur" == "crowdsec" ]] && idx=2
    ask_choice "Host-level security tool" "$idx" \
        "Fail2ban|Lightweight SSH brute-force protection" \
        "CrowdSec|Community threat-intel engine with shared blocklists"
    case "$REPLY" in
        1) state_set SECURITY_TOOL fail2ban ;;
        2) state_set SECURITY_TOOL crowdsec ;;
    esac
}

check_security_choice() { return 1; }
run_security_choice()   { log "Security tool: $(state_get SECURITY_TOOL)"; }

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_security_choice
    configure_security_choice
    run_security_choice
fi
