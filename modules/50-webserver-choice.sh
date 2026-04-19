# shellcheck shell=bash
# =============================================================================
# 50-webserver-choice.sh — Host-level reverse-proxy selector
# =============================================================================
#
# Offered on every host. Operator picks one of nginx / apache / openresty,
# or "none" to skip. The chosen installer (51/52/53) runs on the next step;
# the other two have their applies_ return false based on WEBSERVER_KIND.
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

    # Default to OpenResty. All three install from their upstream repos for
    # latest versions, but only OpenResty ships Lua built-in — that's what
    # the CrowdSec L7 bouncer requires. Upstream nginx and Apache get the
    # host-level iptables bouncer (L3/L4) from 30-intrusion; no L7 WAF via
    # CrowdSec on those paths.
    local default=1
    case "$(state_get WEBSERVER_KIND)" in
        openresty) default=1 ;;
        nginx)     default=2 ;;
        apache)    default=3 ;;
    esac
    ask_choice "Reverse-proxy web server" "$default" \
        "openresty|nginx + Lua built-in (recommended; full CrowdSec L7 bouncer)" \
        "nginx|Upstream nginx.org stable (no Lua; host L3/L4 CrowdSec only)" \
        "apache|Apache httpd from ppa:ondrej/apache2 (no L7 CrowdSec bouncer)"
    case "$REPLY" in
        1) state_set WEBSERVER_KIND openresty ;;
        2) state_set WEBSERVER_KIND nginx ;;
        3) state_set WEBSERVER_KIND apache ;;
    esac

    ask_input "Server name (FQDN for default vhost / LE cert; blank to skip LE)" \
        "$(state_get WEBSERVER_DOMAIN)"
    state_set WEBSERVER_DOMAIN "$REPLY"

    if [[ -n "$(state_get WEBSERVER_DOMAIN)" ]]; then
        ask_input "Email address for Let's Encrypt notifications" \
            "$(state_get WEBSERVER_EMAIL)"
        state_set WEBSERVER_EMAIL "$REPLY"
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
