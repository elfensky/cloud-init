# shellcheck shell=bash
# =============================================================================
# 32-crowdsec-host.sh — CrowdSec + iptables bouncer (host-level)
# =============================================================================
#
# Installs crowdsec + crowdsec-firewall-bouncer-iptables. Optionally enrolls
# the host in the CrowdSec console.
#
# Private-net awareness: appends NET_PRIVATE_CIDR to CrowdSec's whitelist
# parser so intra-server admin traffic never triggers bouncer decisions.
# File: /etc/crowdsec/parsers/s02-enrich/whitelists.yaml
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_crowdsec_host() { [[ "$(state_get SECURITY_TOOL)" == crowdsec ]]; }

detect_crowdsec_host() { return 0; }

configure_crowdsec_host() {
    if [[ -n "$(state_get CROWDSEC_ENROLL_KEY)" ]]; then
        if ! ask_yesno "Keep existing CrowdSec enrollment key on file?" "y"; then
            ask_input "CrowdSec enrollment key (blank to skip)" ""
            state_set CROWDSEC_ENROLL_KEY "$REPLY"
        fi
    elif ask_yesno "Enroll CrowdSec in the console dashboard?" "n"; then
        ask_input "CrowdSec enrollment key" ""
        state_set CROWDSEC_ENROLL_KEY "$REPLY"
    fi
}

check_crowdsec_host() {
    command -v cscli >/dev/null 2>&1 && systemctl is-active --quiet crowdsec
}

run_crowdsec_host() {
    # Official installer script adds the repository and gpg key.
    curl -s https://install.crowdsec.net | bash
    apt-get install -y crowdsec crowdsec-firewall-bouncer-iptables

    # Whitelist the private CIDR so intra-server traffic is never bounced.
    local priv_cidr
    priv_cidr="$(state_get NET_PRIVATE_CIDR)"
    if [[ -n "$priv_cidr" ]]; then
        mkdir -p /etc/crowdsec/parsers/s02-enrich
        cat > /etc/crowdsec/parsers/s02-enrich/private-whitelist.yaml <<EOF
name: cloud/private-whitelist
description: "Whitelist intra-server private CIDR"
whitelist:
  reason: "private network (cloud-init)"
  cidr:
    - "${priv_cidr}"
EOF
        log "CrowdSec whitelist: ${priv_cidr}"
    fi

    local key
    key="$(state_get CROWDSEC_ENROLL_KEY)"
    if [[ -n "$key" ]]; then
        cscli console enroll -e context "$key" || warn "CrowdSec enrollment failed."
        warn "Accept the enrollment in the CrowdSec dashboard."
    fi

    systemctl restart crowdsec
    log "CrowdSec installed and running"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_crowdsec_host || { info "Not selected; skipping."; exit 0; }
    configure_crowdsec_host
    check_crowdsec_host && { log "Already configured; skipping."; exit 0; }
    run_crowdsec_host
fi
