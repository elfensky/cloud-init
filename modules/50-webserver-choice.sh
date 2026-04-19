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
    if ! ask_yesno "Install a host-level reverse-proxy web server?" "n"; then
        state_set WEBSERVER_KIND none
        state_mark_skipped webserver_choice
        return 0
    fi

    local default
    case "$(state_get WEBSERVER_KIND)" in
        nginx)     default=1 ;;
        apache)    default=2 ;;
        openresty) default=3 ;;
        *)         default=1 ;;
    esac
    ask_choice "Reverse-proxy web server" "$default" \
        "nginx|Standard nginx (Ubuntu package)" \
        "apache|Apache httpd with mod_ssl + mod_proxy" \
        "openresty|nginx + Lua; hosts the CrowdSec bouncer natively"
    case "$REPLY" in
        1) state_set WEBSERVER_KIND nginx ;;
        2) state_set WEBSERVER_KIND apache ;;
        3) state_set WEBSERVER_KIND openresty ;;
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
fi
