# shellcheck shell=bash
# =============================================================================
# 25-firewall.sh — UFW with multi-network rules
# =============================================================================
#
# Public network (NET_PUBLIC_IFACE, always present):
#   SSH on the configured SSH_PORT. HTTP/HTTPS only when the operator opts in
#   (or when a web server / reverse proxy was selected earlier in the run).
#
# Private network (NET_PRIVATE_IFACE, if NET_HAS_PRIVATE=yes):
#   Allow-all on the private interface. Intra-server traffic (etcd, kubelet,
#   exporters, DB replication) changes as components come and go — a port
#   allow-list on a trusted private net is fragile and adds no real security
#   over deny-from-public.
#
# When NET_HAS_PRIVATE=no, the private-net rule collapses away.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_firewall() { return 0; }

detect_firewall() {
    # UFW status is the canonical source of truth; no state to import.
    return 0
}

configure_firewall() {
    if ! ask_yesno "Configure UFW host firewall?" "y"; then
        state_mark_skipped firewall
        return 0
    fi

    # Default HTTP open to YES if the operator has already selected Docker or
    # a host-level web server earlier in the wizard; otherwise NO. The user
    # can override in either direction.
    local http_default="n"
    [[ "$(state_get STEP_docker_SELECTED)" == "yes" ]] && http_default="y"
    [[ -n "$(state_get WEBSERVER_KIND)" && "$(state_get WEBSERVER_KIND)" != "none" ]] && http_default="y"

    if ask_yesno "Open HTTP/HTTPS (80/443) on the public interface?" "$http_default"; then
        state_set FIREWALL_OPEN_HTTP yes
    else
        state_set FIREWALL_OPEN_HTTP no
    fi
}

check_firewall()  { return 1; }  # UFW reset is cheap; always re-run.

verify_firewall() {
    # Active UFW + SSH rule present.
    ufw status 2>/dev/null | grep -q "Status: active" || return 1
    local port
    port="$(state_get SSH_PORT 22)"
    ufw status 2>/dev/null | grep -qE "^${port}/tcp |^.* ALLOW .*${port}" || return 1
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
    log "UFW enabled — public=${pub_if:-any} http=${open_http} private=${priv_if:-none}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_firewall
    configure_firewall
    state_skipped firewall && exit 0
    run_firewall
    verify_firewall || { err "Firewall verification failed"; exit 1; }
fi
