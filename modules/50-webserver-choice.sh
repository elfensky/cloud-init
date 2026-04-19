# shellcheck shell=bash
# =============================================================================
# 50-webserver-choice.sh — Host-level reverse-proxy selector
# =============================================================================
#
# Only applies to docker / bare profiles. k8s profile uses ingress-nginx
# inside the cluster (72-ingress-nginx.sh), NOT a host-level web server.
#
# WEBSERVER_KIND ∈ {nginx, apache, openresty, none}
#   default: "nginx" on docker, "none" on bare.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_webserver_choice() {
    local p
    p="$(state_get PROFILE)"
    [[ "$p" == "docker" || "$p" == "bare" ]]
}

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
    local default idx
    case "$(state_get WEBSERVER_KIND)" in
        nginx)     default=1 ;;
        apache)    default=2 ;;
        openresty) default=3 ;;
        none)      default=4 ;;
        *)
            # First run: pick a sensible per-profile default.
            [[ "$(state_get PROFILE)" == "docker" ]] && default=1 || default=4
            ;;
    esac
    ask_choice "Host-level web server (reverse proxy)" "$default" \
        "nginx|Standard nginx (Ubuntu package)" \
        "apache|Apache httpd with mod_ssl + mod_proxy" \
        "openresty|OpenResty (nginx + Lua); can host the CrowdSec bouncer" \
        "none|Skip; configure manually later"
    case "$REPLY" in
        1) idx=nginx ;;
        2) idx=apache ;;
        3) idx=openresty ;;
        4) idx=none ;;
    esac
    state_set WEBSERVER_KIND "$idx"

    if [[ "$idx" != "none" ]]; then
        if [[ -n "$(state_get WEBSERVER_DOMAIN)" ]]; then
            ask_input "Server name (FQDN for default vhost / LE cert)" \
                "$(state_get WEBSERVER_DOMAIN)"
        else
            ask_input "Server name (FQDN for default vhost / LE cert, blank to skip LE)" ""
        fi
        state_set WEBSERVER_DOMAIN "$REPLY"

        if [[ -n "$(state_get WEBSERVER_DOMAIN)" ]]; then
            ask_input "Email address for Let's Encrypt notifications" \
                "$(state_get WEBSERVER_EMAIL)"
            state_set WEBSERVER_EMAIL "$REPLY"
        fi
    fi
}

check_webserver_choice() { return 1; }  # downstream modules decide
run_webserver_choice()   { log "Web server: $(state_get WEBSERVER_KIND)"; }

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_webserver_choice || { info "Not applicable to this profile; skipping."; exit 0; }
    detect_webserver_choice
    configure_webserver_choice
    run_webserver_choice
fi
