# shellcheck shell=bash
# =============================================================================
# 50-webserver-choice.sh — Host-level reverse-proxy selector
# =============================================================================
#
# Offered on every host. Operator picks one of nginx / apache / openresty,
# or "none" to skip. The chosen installer (51/52/53) runs on the next step;
# the other two have their applies_ return false based on WEBSERVER_KIND.
#
# Two dimensions are collected here:
#   - WEBSERVER_SHAPE ∈ {single, multi, other} — the operator's intent for
#     this host. Drives whether the wizard auto-wires a default vhost + LE
#     cert (single) or just installs the engine and lets the operator add
#     per-site vhosts + certs (multi / other).
#   - WEBSERVER_KIND ∈ {openresty, nginx, apache} — the engine to install.
#
# Domain + LE email are only collected in shape=single; shape={multi,other}
# clears WEBSERVER_DOMAIN so 54-tls-certs' `applies_` returns false.
#
# Note: a K8s node CAN still install a host-level reverse proxy (for
# non-cluster services). That's why this isn't gated on RKE2 selection.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_webserver_choice() { return 0; }

detect_webserver_choice() {
    if systemctl is-active --quiet nginx 2>/dev/null; then
        state_set WEBSERVER_KIND nginx
    elif systemctl is-active --quiet apache2 2>/dev/null; then
        state_set WEBSERVER_KIND apache
    elif systemctl is-active --quiet openresty 2>/dev/null; then
        state_set WEBSERVER_KIND openresty
    fi
}

configure_webserver_choice() {
    info "Terminates TLS and proxies to local apps — skip this if RKE2's"
    info "ingress-nginx will handle all inbound HTTP/HTTPS on this host."
    if ! ask_yesno "Install a host-level reverse-proxy web server (openresty/nginx/apache)?" "n"; then
        state_set WEBSERVER_KIND none
        state_mark_skipped webserver_choice
        return 0
    fi

    # Shape first — drives whether the wizard wires a domain+TLS or just
    # installs the engine for the operator to configure per-site later.
    info "Shape of this host's web usage — determines what the wizard wires up:"
    info "  single-site: one domain on this VPS → default vhost + LE cert auto."
    info "  multi-site:  several public sites → you add per-site vhosts + certs."
    info "  other:       internal dashboards / proxy-only / Tailscale-scoped →"
    info "               the wizard just installs the engine with a benign default."
    local shape_default=1
    case "$(state_get WEBSERVER_SHAPE)" in
        single) shape_default=1 ;;
        multi)  shape_default=2 ;;
        other)  shape_default=3 ;;
    esac
    ask_choice "Web server shape" "$shape_default" \
        "single-site|one public domain on this VPS — wizard wires default vhost + TLS" \
        "multi-site|multiple public domains — you add per-site vhosts + certs" \
        "other|internal / proxy-only / advanced — wizard installs engine only"
    case "$REPLY" in
        1) state_set WEBSERVER_SHAPE single ;;
        2) state_set WEBSERVER_SHAPE multi ;;
        3) state_set WEBSERVER_SHAPE other ;;
    esac

    # Engine choice. Default to OpenResty — all three install from their
    # upstream repos for latest versions, but only OpenResty ships Lua
    # built-in, which is what the CrowdSec L7 bouncer requires. Upstream
    # nginx and Apache get only the host-level iptables bouncer (L3/L4)
    # from 30-intrusion; no L7 WAF via CrowdSec on those paths.
    local engine_default=1
    case "$(state_get WEBSERVER_KIND)" in
        openresty) engine_default=1 ;;
        nginx)     engine_default=2 ;;
        apache)    engine_default=3 ;;
    esac
    ask_choice "Reverse-proxy web server" "$engine_default" \
        "openresty|nginx + Lua built-in (recommended; full CrowdSec L7 bouncer)" \
        "nginx|Upstream nginx.org stable (no Lua; host L3/L4 CrowdSec only)" \
        "apache|Apache httpd from ppa:ondrej/apache2 (no L7 CrowdSec bouncer)"
    case "$REPLY" in
        1) state_set WEBSERVER_KIND openresty ;;
        2) state_set WEBSERVER_KIND nginx ;;
        3) state_set WEBSERVER_KIND apache ;;
    esac

    # Domain + LE email only relevant in single-site mode. For multi/other,
    # actively clear WEBSERVER_DOMAIN so 54-tls-certs' applies_ returns false
    # (handles --redo after flipping shape from single → multi).
    if [[ "$(state_get WEBSERVER_SHAPE)" == single ]]; then
        info "The single domain this VPS will serve. Used as server_name on the"
        info "default virtual host AND as the CN on a Let's Encrypt cert at step 54."
        info "DNS must already point to this host for the HTTP-01 challenge to pass"
        info "(or pick DNS-01 with provider credentials at step 54 for wildcards)."
        ask_input "Domain name (e.g. apps.example.com)" \
            "$(state_get WEBSERVER_DOMAIN)"
        state_set WEBSERVER_DOMAIN "$REPLY"

        info "Let's Encrypt uses this email for expiry warnings and policy notices."
        info "Doesn't have to match the domain; any address you monitor is fine."
        ask_input "Email address for Let's Encrypt notifications" \
            "$(state_get WEBSERVER_EMAIL)"
        state_set WEBSERVER_EMAIL "$REPLY"
    else
        state_set WEBSERVER_DOMAIN ""
        state_set WEBSERVER_EMAIL ""
    fi
}

check_webserver_choice() { return 1; }  # no canonical state; downstream modules verify

verify_webserver_choice() {
    # Verifying "the user picked something" is just ensuring WEBSERVER_KIND is set.
    [[ -n "$(state_get WEBSERVER_KIND)" ]]
}

run_webserver_choice() {
    log "Web server: $(state_get WEBSERVER_KIND)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_webserver_choice
    configure_webserver_choice
    state_skipped webserver_choice && exit 0
    run_webserver_choice
    verify_webserver_choice || { err "Webserver choice not recorded"; exit 1; }
fi
