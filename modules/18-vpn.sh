# shellcheck shell=bash
# =============================================================================
# 18-vpn.sh — Optional VPN: Tailscale OR raw WireGuard (installs early)
# =============================================================================
#
# Runs before 24-ssh-harden and 25-firewall so those modules can offer VPN-
# aware options conditional on VPN_KIND:
#   - 24-ssh-harden: enables Tailscale SSH (tailscaled's identity+ACL SSH
#     server) ONLY when VPN_KIND=tailscale — WireGuard has no equivalent.
#   - 25-firewall:   SSH scope selector uses VPN_IFACE (tailscale0 or wg0)
#                    in its rules; the "VPN only" scope shows a console-
#                    recovery warning before it's applied.
#
# State:
#   VPN_KIND    none | tailscale | wireguard
#   VPN_IFACE   ""   | tailscale0 | <user-chosen, default wg0>
#   VPN_ENABLED no | yes (convenience flag: yes iff VPN_KIND != none)
#
# Back-compat: an older state.env with TAILSCALE_ENABLED=yes maps to
# VPN_KIND=tailscale at detect time, so re-runs on existing installs don't
# break and don't re-prompt.
#
# Comparison at a glance (shown to operator before choosing):
#
#                      Tailscale                     WireGuard (raw)
#   ------------------  ----------------------------  -------------------------------
#   Zero-config         yes (auto key exchange)       no (bring your own config)
#   Account required    yes (SSO login)               no
#   Free-tier caps      100 devices, 3 users (2025)   unlimited
#   Coordination        Tailscale SaaS (metadata)     none (direct peer-to-peer)
#   NAT traversal       auto (DERP relays)            manual (need reachable endpoint)
#   Identity / ACLs     built in                      keys-only
#   One-way tunnel      via tailnet ACLs              via wizard conntrack option
#   Typical fit         laptops/phones, fleets        fixed site-to-site, UniFi, gw
#
# WireGuard one-way: when the server should never initiate connections back
# over the tunnel (common for UniFi home-network peers), the module injects
# PostUp/PreDown iptables rules into the [Interface] section that drop
# outbound packets on the VPN interface except RELATED,ESTABLISHED. This
# gives "home router NAT" semantics on top of the tunnel.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_vpn() { return 0; }

detect_vpn() {
    # Back-compat: upgrade old TAILSCALE_ENABLED state to the new schema.
    if [[ -z "$(state_get VPN_KIND)" ]]; then
        local legacy
        legacy="$(state_get TAILSCALE_ENABLED)"
        case "$legacy" in
            yes) state_set VPN_KIND tailscale; state_set VPN_IFACE tailscale0; state_set VPN_ENABLED yes ;;
            no)  state_set VPN_KIND none;      state_set VPN_IFACE "";          state_set VPN_ENABLED no  ;;
        esac
    fi

    # Detect already-installed VPN tooling so re-runs don't reprompt from scratch.
    if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
        [[ -z "$(state_get VPN_KIND)" ]] && { state_set VPN_KIND tailscale; state_set VPN_IFACE tailscale0; state_set VPN_ENABLED yes; }
    fi
    return 0
}

configure_vpn() {
    info "A VPN lets you reach this host privately from laptops/other servers"
    info "and affects later SSH / firewall options at modules 24 and 25."
    if ! ask_yesno "Install a VPN on this host?" "n"; then
        state_set VPN_KIND none
        state_set VPN_IFACE ""
        state_set VPN_ENABLED no
        state_mark_skipped vpn
        return 0
    fi

    # Compact comparison so the choice is informed. The module header has the
    # fuller table; these lines are the tl;dr operators see at the prompt.
    info ""
    info "Tailscale vs WireGuard — pick the one that fits:"
    info "  • Tailscale — zero-config; Tailscale account required; free ≤100 devices;"
    info "                auto NAT-traversal via DERP; built-in identity + ACLs."
    info "  • WireGuard — you paste a peer config (from UniFi, WG-Easy, self-hosted);"
    info "                no account, no vendor; manual keys; needs reachable endpoint"
    info "                on at least one side; wizard offers a one-way egress block."
    info ""

    ask_choice "Which VPN?" "1" \
        "Tailscale|zero-config mesh VPN (account required)" \
        "WireGuard|raw WireGuard — paste a peer config (UniFi, self-hosted)"

    case "$REPLY" in
        1)
            state_set VPN_KIND tailscale
            state_set VPN_IFACE tailscale0
            state_set VPN_ENABLED yes
            ;;
        2)
            state_set VPN_KIND wireguard
            state_set VPN_ENABLED yes
            _configure_wireguard
            ;;
    esac
}

# WireGuard-specific sub-prompts: interface name, paste config, one-way toggle.
_configure_wireguard() {
    # Interface name. Default wg0. Operators with multiple WG tunnels may
    # want a distinct name (e.g. 'unifi0', 'wg-home') — allow override.
    ask_input "WireGuard interface name" "$(state_get VPN_IFACE wg0)" '^[a-zA-Z][a-zA-Z0-9_-]*$'
    state_set VPN_IFACE "$REPLY"

    info ""
    info "Paste the WireGuard config from your peer (UniFi admin → WireGuard → Add"
    info "Client; or WG-Easy / wg-gen-web / hand-rolled). Must contain [Interface]"
    info "with Address + PrivateKey and ≥1 [Peer] with PublicKey + AllowedIPs."
    info "End the paste with a single line containing exactly: EOF"

    # Retry on validation failure rather than forcing a full --redo 18-vpn for
    # a paste typo. The opt-out path routes through state_mark_skipped because
    # configure_ MUST return 0 — a non-zero return trips main.sh's set -e
    # before its "⊘ skipped" branch can fire, silently halting the wizard.
    local block line
    while true; do
        block=""
        echo ""
        while IFS= read -r line; do
            [[ "$line" == "EOF" ]] && break
            block+="${line}"$'\n'
        done

        if _validate_wg_config "$block"; then
            break
        fi
        if ! ask_yesno "Retry paste?" "y"; then
            state_mark_skipped vpn
            return 0
        fi
    done
    state_set VPN_WG_CONFIG "$block"

    info ""
    info "One-way tunnels block server-initiated egress over the VPN while letting"
    info "responses to inbound connections through (iptables conntrack rules in"
    info "PostUp/PreDown). Matches the UniFi / home-router model: you connect IN,"
    info "the server can't initiate OUT. DNS-via-tunnel stops working in this mode."
    if ask_yesno "Make this a one-way tunnel (block server-initiated egress)?" "y"; then
        state_set VPN_WG_ONEWAY yes
    else
        state_set VPN_WG_ONEWAY no
    fi
}

_validate_wg_config() {
    local cfg="$1"
    grep -qE '^\[Interface\]'           <<< "$cfg" || { err "Missing [Interface] section"; return 1; }
    grep -qE '^Address[[:space:]]*='    <<< "$cfg" || { err "Missing 'Address = ...' in [Interface]"; return 1; }
    grep -qE '^PrivateKey[[:space:]]*=' <<< "$cfg" || { err "Missing 'PrivateKey = ...' in [Interface]"; return 1; }
    grep -qE '^\[Peer\]'                <<< "$cfg" || { err "No [Peer] section found"; return 1; }
    grep -qE '^PublicKey[[:space:]]*='  <<< "$cfg" || { err "Missing 'PublicKey = ...' in [Peer]"; return 1; }
    return 0
}

# Inject one-way PostUp/PreDown iptables rules right after the [Interface]
# header so they land in the correct section regardless of surrounding order.
_inject_oneway() {
    local cfg="$1" iface="$2"
    awk -v i="$iface" '
        /^\[Interface\][[:space:]]*$/ {
            print
            print "# One-way tunnel (18-vpn.sh): allow responses, block server-initiated egress."
            print "PostUp  = iptables -A OUTPUT -o " i " -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
            print "PostUp  = iptables -A OUTPUT -o " i " -j DROP"
            print "PreDown = iptables -D OUTPUT -o " i " -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
            print "PreDown = iptables -D OUTPUT -o " i " -j DROP"
            next
        }
        { print }
    ' <<< "$cfg"
}

check_vpn() {
    case "$(state_get VPN_KIND none)" in
        tailscale) command -v tailscale >/dev/null 2>&1 ;;
        wireguard) command -v wg >/dev/null 2>&1 ;;
        *)         return 0 ;;
    esac
}

verify_vpn() {
    case "$(state_get VPN_KIND none)" in
        tailscale)
            command -v tailscale >/dev/null 2>&1 || return 1
            systemctl is-active tailscaled >/dev/null 2>&1 || return 1
            tailscale status >/dev/null 2>&1 || return 1
            ;;
        wireguard)
            local iface
            iface="$(state_get VPN_IFACE wg0)"
            command -v wg >/dev/null 2>&1 || return 1
            systemctl is-active "wg-quick@${iface}" >/dev/null 2>&1 || return 1
            # 'wg show <iface>' exits non-zero if the interface doesn't exist.
            wg show "$iface" >/dev/null 2>&1 || return 1
            ;;
        none) return 0 ;;
    esac
}

run_vpn() {
    case "$(state_get VPN_KIND none)" in
        tailscale) _run_tailscale ;;
        wireguard) _run_wireguard ;;
        none)      log "No VPN selected." ;;
    esac
}

_run_tailscale() {
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up
    log "Tailscale connected (tailnet IP: $(tailscale ip -4 2>/dev/null | head -n1))"
}

_run_wireguard() {
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get install -y -qq wireguard; then
        err "apt-get install wireguard failed — see /var/log/apt/term.log"
        exit 1
    fi

    local iface cfg oneway final_cfg
    iface="$(state_get VPN_IFACE wg0)"
    cfg="$(state_get VPN_WG_CONFIG)"
    oneway="$(state_get VPN_WG_ONEWAY no)"

    if [[ -z "$cfg" ]]; then
        err "VPN_WG_CONFIG is empty — nothing to write to /etc/wireguard/${iface}.conf"
        exit 1
    fi

    if [[ "$oneway" == yes ]]; then
        final_cfg="$(_inject_oneway "$cfg" "$iface")"
    else
        final_cfg="$cfg"
    fi

    umask 077
    printf '%s' "$final_cfg" > "/etc/wireguard/${iface}.conf"
    chmod 0600 "/etc/wireguard/${iface}.conf"
    chown root:root "/etc/wireguard/${iface}.conf"

    systemctl enable --now "wg-quick@${iface}"

    # Brief grace period for the interface to appear before main.sh's verify.
    local i=0
    while ! wg show "$iface" >/dev/null 2>&1; do
        ((i++)); ((i > 10)) && break
        sleep 1
    done

    log "WireGuard up on ${iface} (one-way=${oneway})"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_vpn
    configure_vpn
    state_skipped vpn && exit 0
    check_vpn && { log "VPN tooling already present."; }
    run_vpn
    verify_vpn || { err "VPN verification failed"; exit 1; }
fi
