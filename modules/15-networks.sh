# shellcheck shell=bash
# =============================================================================
# 15-networks.sh — Public and private network detection
# =============================================================================
#
# Detects the host's public interface (default route) and optional private
# interface (RFC1918 on a secondary NIC). Operator confirms or overrides.
# Writes to state:
#   NET_PUBLIC_IFACE     — e.g. eth0
#   NET_PUBLIC_IP        — primary public IPv4
#   NET_PRIVATE_IFACE    — e.g. enp7s0, or empty if none
#   NET_PRIVATE_IP       — primary private IPv4, or empty
#   NET_PRIVATE_CIDR     — private CIDR used for allow-lists, or empty
#   NET_HAS_PRIVATE      — "yes" or "no"
#
# When NET_HAS_PRIVATE=no, all downstream modules collapse private-net rules
# to single-network behaviour (matches today's "standalone" defaults).
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_networks() { return 0; }

# Detect from running kernel state. Populates state vars.
detect_networks() {
    # Public interface: default route.
    if detect_public_iface 2>/dev/null; then
        state_set NET_PUBLIC_IFACE "$PUBLIC_IFACE"
        local pub_ip
        pub_ip="$(ip -4 -o addr show dev "$PUBLIC_IFACE" \
                  | awk '{print $4}' | cut -d/ -f1 | head -n1)"
        [[ -n "$pub_ip" ]] && state_set NET_PUBLIC_IP "$pub_ip"
    fi

    # Private interface: RFC1918 on a non-default iface.
    if detect_private_iface 2>/dev/null; then
        state_set NET_PRIVATE_IFACE "$PRIVATE_IFACE"
        if get_private_ip "$PRIVATE_IFACE" 2>/dev/null; then
            state_set NET_PRIVATE_IP "$PRIVATE_IP"
            # Derive CIDR from the interface's assigned network.
            local cidr
            cidr="$(ip -4 -o addr show dev "$PRIVATE_IFACE" \
                    | awk '{print $4}' | head -n1)"
            if [[ -n "$cidr" ]]; then
                # Normalise host-bits → network-bits (e.g. 10.0.0.5/24 → 10.0.0.0/24)
                local prefix ip net
                ip="${cidr%/*}"
                prefix="${cidr#*/}"
                # Use python for correct mask arithmetic; fall back to raw if missing.
                if command -v python3 >/dev/null 2>&1; then
                    net="$(python3 -c "import ipaddress,sys; print(ipaddress.ip_network('$ip/$prefix', strict=False))" 2>/dev/null || echo "$cidr")"
                else
                    net="$cidr"
                fi
                state_set NET_PRIVATE_CIDR "$net"
            fi
        fi
    fi

    if [[ -n "$(state_get NET_PRIVATE_IFACE)" ]]; then
        state_set NET_HAS_PRIVATE yes
    else
        state_set NET_HAS_PRIVATE no
    fi
}

configure_networks() {
    # Confirm / override public interface + IP.
    ask_input "Public interface" "$(state_get NET_PUBLIC_IFACE)"
    state_set NET_PUBLIC_IFACE "$REPLY"
    ask_input "Public IPv4" "$(state_get NET_PUBLIC_IP)"
    state_set NET_PUBLIC_IP "$REPLY"

    # Does this host have a private network?
    local default_priv
    default_priv="$([[ "$(state_get NET_HAS_PRIVATE no)" == yes ]] && echo y || echo n)"
    if ask_yesno "Does this host have a private (intra-server) network?" "$default_priv"; then
        ask_input "Private interface" "$(state_get NET_PRIVATE_IFACE)"
        state_set NET_PRIVATE_IFACE "$REPLY"
        ask_input "Private IPv4" "$(state_get NET_PRIVATE_IP)"
        state_set NET_PRIVATE_IP "$REPLY"
        local cur_cidr
        cur_cidr="$(state_get NET_PRIVATE_CIDR)"
        while true; do
            ask_input "Private CIDR (for allow-lists)" "$cur_cidr"
            if validate_cidr "$REPLY"; then
                state_set NET_PRIVATE_CIDR "$REPLY"
                break
            fi
            err "Invalid CIDR: $REPLY"
        done
        state_set NET_HAS_PRIVATE yes
    else
        state_set NET_PRIVATE_IFACE ""
        state_set NET_PRIVATE_IP ""
        state_set NET_PRIVATE_CIDR ""
        state_set NET_HAS_PRIVATE no
    fi
}

check_networks() { return 1; }  # Always re-runnable; emits a summary.

verify_networks() {
    # Detection succeeded if we have at least a public interface. A private
    # network is optional and is reflected in NET_HAS_PRIVATE.
    [[ -n "$(state_get NET_PUBLIC_IFACE)" ]]
}

run_networks() {
    local has_priv
    has_priv="$(state_get NET_HAS_PRIVATE)"
    log "Public:  $(state_get NET_PUBLIC_IFACE) $(state_get NET_PUBLIC_IP)"
    if [[ "$has_priv" == yes ]]; then
        log "Private: $(state_get NET_PRIVATE_IFACE) $(state_get NET_PRIVATE_IP) ($(state_get NET_PRIVATE_CIDR))"
    else
        log "Private: (none)"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_networks
    configure_networks
    run_networks
fi
