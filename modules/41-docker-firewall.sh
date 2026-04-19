# shellcheck shell=bash
# =============================================================================
# 41-docker-firewall.sh — DOCKER-USER chain rules (network-aware)
# =============================================================================
#
# Docker inserts its own rules into FORWARD (via DOCKER-USER chain) that run
# BEFORE UFW's rules, which means bound container ports bypass UFW's deny
# policy. The fix is to explicitly place rules in the DOCKER-USER chain:
#   - Allow from NET_PRIVATE_CIDR (intra-server is trusted)
#   - Drop everything else by default
#   - Specific public ingress is then enabled per-container manually
#
# Rules are made persistent via iptables-persistent.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_docker_firewall() { [[ "$(state_get PROFILE)" == docker ]]; }

detect_docker_firewall()   { return 0; }
configure_docker_firewall(){ return 0; }

check_docker_firewall() {
    iptables -L DOCKER-USER -n 2>/dev/null | grep -q "cloud-init:docker-firewall"
}

run_docker_firewall() {
    # iptables-persistent preseeds: save current rules now so the installer
    # doesn't prompt.
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true"  | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean true"  | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent

    # Flush our previously-tagged rules if re-running.
    while iptables -D DOCKER-USER -m comment --comment "cloud-init:docker-firewall" -j RETURN 2>/dev/null; do :; done

    local priv_cidr
    priv_cidr="$(state_get NET_PRIVATE_CIDR)"
    if [[ -n "$priv_cidr" ]]; then
        iptables -I DOCKER-USER -s "$priv_cidr" \
            -m comment --comment "cloud-init:docker-firewall" -j RETURN
    fi
    iptables -I DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED \
        -m comment --comment "cloud-init:docker-firewall" -j RETURN

    # Default drop for anything not explicitly allowed (operator adds per-port
    # rules above this one for public ingress).
    iptables -A DOCKER-USER -m comment --comment "cloud-init:docker-firewall" -j DROP

    netfilter-persistent save >/dev/null 2>&1 || iptables-save > /etc/iptables/rules.v4
    log "Docker firewall (DOCKER-USER chain) configured; private allow: ${priv_cidr:-none}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_docker_firewall || exit 0
    check_docker_firewall && { log "Already configured; skipping."; exit 0; }
    run_docker_firewall
fi
