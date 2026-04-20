# shellcheck shell=bash
# =============================================================================
# 25-firewall.sh — UFW with multi-network rules and SSH scope selection
# =============================================================================
#
# Public network (NET_PUBLIC_IFACE, always present):
#   HTTP/HTTPS only when the operator opts in (or when a web server / reverse
#   proxy was selected earlier in the run). SSH presence depends on SSH_SCOPE.
#
# Private network (NET_PRIVATE_IFACE, if NET_HAS_PRIVATE=yes):
#   Allow-all on the private interface. Intra-server traffic (etcd, kubelet,
#   exporters, DB replication) changes as components come and go — a port
#   allow-list on a trusted private net is fragile and adds no real security
#   over deny-from-public. SSH_SCOPE=tailnet_only adds a targeted deny for the
#   SSH port on this interface, keeping the allow-all for everything else.
#
# Tailnet (tailscale0, if TAILSCALE_ENABLED=yes from 18-tailscale):
#   Allow-all on the tailscale0 interface. Tailscale does its own identity +
#   ACL enforcement at the WireGuard + tailscaled layer.
#
# SSH_SCOPE controls WHERE on the host the SSH port (SSH_PORT) is reachable:
#   - all          : public + private + tailnet (classical, default)
#   - no_public    : block public; private + tailnet allowed
#   - tailnet_only : block public AND private; tailnet only (⚠ console-recovery
#                    dependency if Tailscale breaks; warned at configure time)
#
# SSH_SCOPE is set by _configure_ssh_scope based on what's available: with
# neither Tailscale nor private LAN, the scope collapses to 'all' without
# asking (no meaningful choice exists). When NET_HAS_PRIVATE=no the private
# rule block is skipped entirely.
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
    info "Host packet filter: default-deny incoming, allow SSH + selected ports."
    info "Complements (not replaces) intrusion detection in the next step."
    if ! ask_yesno "Configure host firewall (ufw)?" "y"; then
        state_mark_skipped firewall
        return 0
    fi

    # Default the HTTP-open question to "y". 25 runs before 40-docker and
    # 50-webserver-choice, so it can't know what the operator will pick at
    # those steps — hence we don't try to infer. Most hosts want 80/443 open
    # anyway. If the operator answers "n" and later installs Docker or a
    # host reverse proxy, they can re-run:  sudo ./main.sh --redo 25-firewall
    if ask_yesno "Open HTTP/HTTPS (80/443) on the public interface?" "y"; then
        state_set FIREWALL_OPEN_HTTP yes
    else
        state_set FIREWALL_OPEN_HTTP no
    fi

    _configure_ssh_scope
}

# Asks where SSH should be reachable from. Options depend on what earlier
# steps enabled — tailnet (18-tailscale) and private network (15-networks).
# The default is always "anywhere" so that a quick wizard run stays unchanged;
# opt-in restriction is a conscious choice by the operator.
_configure_ssh_scope() {
    local has_tailscale has_private ssh_port
    has_tailscale="$(state_get TAILSCALE_ENABLED no)"
    has_private="$(state_get NET_HAS_PRIVATE no)"
    ssh_port="$(state_get SSH_PORT 22)"

    # No tailnet and no private means there's only one answer: public-reachable.
    if [[ "$has_tailscale" != yes && "$has_private" != yes ]]; then
        state_set SSH_SCOPE all
        return 0
    fi

    # Build the "anywhere" option label dynamically.
    local anywhere_desc="public internet"
    [[ "$has_private" == yes ]]   && anywhere_desc+=" + private LAN"
    [[ "$has_tailscale" == yes ]] && anywhere_desc+=" + tailnet"

    info "Decide where port ${ssh_port} is reachable from. UFW only — sshd itself"
    info "keeps listening on all interfaces; this just controls the packet filter."
    if [[ "$has_tailscale" == yes ]]; then
        info "⚠ 'Tailnet only' means: if Tailscale breaks (account lockout, tailscaled"
        info "⚠ crash, coordination-server outage) you lose SSH from the public AND"
        info "⚠ private paths. Recovery requires console/serial access from your host"
        info "⚠ provider — Hetzner provides it, some providers do not. Verify yours."
    fi

    # Assemble the choice list. Index mapping is position-based so we need to
    # track which option corresponds to which scope; do that with parallel arrays.
    local -a labels=() descs=() scopes=()

    labels+=("Anywhere");   descs+=("$anywhere_desc");                              scopes+=("all")
    labels+=("No public");  descs+=("block public; allow everything else");         scopes+=("no_public")
    if [[ "$has_tailscale" == yes ]]; then
        labels+=("Tailnet only"); descs+=("block public AND private LAN; tailnet only"); scopes+=("tailnet_only")
    fi

    local -a opts=()
    local i
    for i in "${!labels[@]}"; do
        opts+=("${labels[$i]}|${descs[$i]}")
    done

    ask_choice "Where should SSH be reachable from?" "1" "${opts[@]}"
    state_set SSH_SCOPE "${scopes[$((REPLY - 1))]}"
}

check_firewall()  { return 1; }  # UFW reset is cheap; always re-run.

verify_firewall() {
    ufw status 2>/dev/null | grep -q "Status: active" || return 1
    # Verification depends on scope: 'all' requires a port-specific allow; the
    # restricted scopes rely on a tailscale0 or private-interface allow-all.
    local port scope
    port="$(state_get SSH_PORT 22)"
    scope="$(state_get SSH_SCOPE all)"
    case "$scope" in
        all)
            ufw status 2>/dev/null | grep -qE "^${port}/tcp |^.* ALLOW .*${port}" || return 1
            ;;
        *)
            ufw status 2>/dev/null | grep -qE "tailscale0|Private network" || return 1
            ;;
    esac
}

run_firewall() {
    apt-get install -y -qq ufw 2>/dev/null
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming
    ufw default allow outgoing

    local ssh_port pub_if priv_if has_priv has_tailscale open_http ssh_scope
    ssh_port="$(state_get SSH_PORT 22)"
    pub_if="$(state_get NET_PUBLIC_IFACE)"
    priv_if="$(state_get NET_PRIVATE_IFACE)"
    has_priv="$(state_get NET_HAS_PRIVATE no)"
    has_tailscale="$(state_get TAILSCALE_ENABLED no)"
    open_http="$(state_get FIREWALL_OPEN_HTTP no)"
    ssh_scope="$(state_get SSH_SCOPE all)"

    # --- Public interface rules -------------------------------------------------
    # HTTP/HTTPS are orthogonal to SSH_SCOPE — a public web server with
    # tailnet-only SSH is a perfectly sensible setup.
    if [[ -n "$pub_if" ]]; then
        if [[ "$ssh_scope" == all ]]; then
            ufw allow in on "$pub_if" to any port "$ssh_port" proto tcp comment 'SSH (public)'
        fi
        if [[ "$open_http" == yes ]]; then
            ufw allow in on "$pub_if" to any port 80 proto tcp  comment 'HTTP (public)'
            ufw allow in on "$pub_if" to any port 443 proto tcp comment 'HTTPS (public)'
        fi
    elif [[ "$ssh_scope" == all ]]; then
        # No named public interface — fall back to an unscoped SSH allow.
        ufw allow "${ssh_port}/tcp" comment 'SSH'
        if [[ "$open_http" == yes ]]; then
            ufw allow 80/tcp  comment 'HTTP'
            ufw allow 443/tcp comment 'HTTPS'
        fi
    fi

    # --- Private interface rules ------------------------------------------------
    # In "tailnet_only" mode we deny SSH specifically on the private interface
    # but keep the allow-all for everything else (DB replication, exporters, etc).
    # UFW evaluates rules in insertion order, so the deny must come first.
    if [[ "$has_priv" == yes && -n "$priv_if" ]]; then
        if [[ "$ssh_scope" == tailnet_only ]]; then
            ufw deny in on "$priv_if" to any port "$ssh_port" proto tcp comment 'SSH blocked on private (tailnet-only)'
        fi
        ufw allow in on "$priv_if" comment 'Private network'
    fi

    # --- Tailnet rules ----------------------------------------------------------
    if [[ "$has_tailscale" == yes ]]; then
        ufw allow in on tailscale0 comment 'Tailscale'
    fi

    ufw --force enable
    log "UFW enabled — ssh_scope=${ssh_scope} public=${pub_if:-any} http=${open_http} private=${priv_if:-none} tailscale=${has_tailscale}"
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
