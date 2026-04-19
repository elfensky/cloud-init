# shellcheck shell=bash
# =============================================================================
# 25-firewall.sh — UFW, profile- AND network-aware
# =============================================================================
#
# Public network (NET_PUBLIC_IFACE, always present):
#   SSH on the configured SSH_PORT, all profiles.
#   HTTP/HTTPS for docker and bare profiles (and also for k8s if the operator
#   opts in — rare, since ingress normally lives inside the cluster).
#
# Private network (NET_PRIVATE_IFACE, if NET_HAS_PRIVATE=yes):
#   Allow-all on the private interface regardless of profile. Intra-server
#   traffic (etcd, kubelet, exporters, DB replication) changes as components
#   come and go — maintaining a port allow-list on a trusted private net is
#   fragile and provides no real security benefit over deny-from-public.
#
# When NET_HAS_PRIVATE=no, private-net rules collapse away entirely.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_firewall() { return 0; }

detect_firewall() {
    # No explicit state to recover; UFW rules themselves are the source of truth.
    return 0
}

configure_firewall() {
    # Whether to open 80/443 on the public interface. Defaults per profile.
    local profile default
    profile="$(state_get PROFILE)"
    case "$profile" in
        docker|bare) default="y" ;;
        k8s|*)       default="n" ;;
    esac
    if ask_yesno "Open HTTP/HTTPS (80/443) on the public interface?" "$default"; then
        state_set FIREWALL_OPEN_HTTP yes
    else
        state_set FIREWALL_OPEN_HTTP no
    fi
}

check_firewall() {
    # Always re-run: UFW reset is cheap and idempotent.
    return 1
}

run_firewall() {
    apt-get install -y -qq ufw 2>/dev/null
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming
    ufw default allow outgoing

    local ssh_port pub_if priv_if has_priv open_http
    ssh_port="$(state_get SSH_PORT 22)"
    pub_if="$(state_get NET_PUBLIC_IFACE)"
    priv_if="$(state_get NET_PRIVATE_IFACE)"
    has_priv="$(state_get NET_HAS_PRIVATE no)"
    open_http="$(state_get FIREWALL_OPEN_HTTP no)"

    if [[ -n "$pub_if" ]]; then
        ufw allow in on "$pub_if" to any port "$ssh_port" proto tcp comment 'SSH (public)'
        if [[ "$open_http" == yes ]]; then
            ufw allow in on "$pub_if" to any port 80 proto tcp  comment 'HTTP (public)'
            ufw allow in on "$pub_if" to any port 443 proto tcp comment 'HTTPS (public)'
        fi
    else
        # Fallback: no detected public iface → open on any iface.
        ufw allow "${ssh_port}/tcp" comment 'SSH'
        if [[ "$open_http" == yes ]]; then
            ufw allow 80/tcp  comment 'HTTP'
            ufw allow 443/tcp comment 'HTTPS'
        fi
    fi

    if [[ "$has_priv" == yes && -n "$priv_if" ]]; then
        ufw allow in on "$priv_if" comment 'Private network'
    fi

    ufw --force enable
    log "UFW enabled — public=$pub_if ($(state_get FIREWALL_OPEN_HTTP | tr 'yn' 'ey')), private=${priv_if:-none}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_firewall
    configure_firewall
    run_firewall
fi
