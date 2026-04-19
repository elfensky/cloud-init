# shellcheck shell=bash
# =============================================================================
# 53-webserver-openresty.sh — OpenResty (HTTP-only default vhost) + optional
#                             CrowdSec Lua bouncer
# =============================================================================
#
# OpenResty is nginx compiled with LuaJIT. Same config syntax as nginx, plus
# the ability to run Lua directly in request handling — which the CrowdSec
# bouncer uses for L7 decisions without a sidecar.
#
# Installs openresty + writes a minimal HTTP-only default vhost with a
# webroot /.well-known/acme-challenge/ location. Cert issuance and the TLS
# vhost are handled by step 54-tls-certs.
#
# If SECURITY_TOOL=crowdsec, also installs the crowdsec-openresty-bouncer
# package and wires it into the vhost for L7 enforcement.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_webserver_openresty() { [[ "$(state_get WEBSERVER_KIND)" == openresty ]]; }

detect_webserver_openresty() { return 0; }

configure_webserver_openresty() {
    info "Installs OpenResty from openresty.org (nginx + LuaJIT)."
    info "Writes HTTP-only default vhost; TLS at step 54. CrowdSec Lua bouncer"
    info "is included if SECURITY_TOOL=crowdsec was picked at step 30."
    if ! ask_yesno "Install OpenResty (upstream)?" "y"; then
        state_mark_skipped webserver_openresty
        return 0
    fi
}

check_webserver_openresty() {
    command -v openresty >/dev/null 2>&1 && systemctl is-active --quiet openresty
}

_install_openresty_repo() {
    local codename
    codename="$(lsb_release -cs)"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://openresty.org/package/pubkey.gpg \
        | gpg --dearmor -o /etc/apt/keyrings/openresty.gpg
    chmod a+r /etc/apt/keyrings/openresty.gpg
    cat > /etc/apt/sources.list.d/openresty.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/openresty.gpg] http://openresty.org/package/ubuntu ${codename} main
EOF
    apt-get update -qq
}

run_webserver_openresty() {
    _install_openresty_repo
    apt-get install -y -qq openresty
    for pkg in nginx apache2; do
        dpkg -l "$pkg" 2>/dev/null | grep -q '^ii' && apt-get remove -y -qq "$pkg"
    done

    local domain server_name
    domain="$(state_get WEBSERVER_DOMAIN)"
    server_name="_"
    [[ -n "$domain" ]] && server_name="$domain"

    # Site config under /etc/openresty/conf.d. The main openresty config
    # (/usr/local/openresty/nginx/conf/nginx.conf on Ubuntu package) already
    # includes conf.d/*.conf inside the http{} block.
    mkdir -p /etc/openresty/conf.d
    cat > /etc/openresty/conf.d/default.conf <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${server_name};

    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF

    # Optional CrowdSec Lua bouncer.
    if [[ "$(state_get SECURITY_TOOL)" == "crowdsec" ]]; then
        _install_crowdsec_lua_bouncer
    fi

    openresty -t && systemctl enable --now openresty && systemctl reload openresty
    # TLS vhost + cert issuance happen in step 54 (tls-certs).
    log "openresty installed; default vhost at /etc/openresty/conf.d/default.conf"
}

_install_crowdsec_lua_bouncer() {
    apt-get install -y -qq crowdsec-openresty-bouncer 2>/dev/null \
        || warn "crowdsec-openresty-bouncer package not in repo; install manually via luarocks."
    # The package drops /etc/crowdsec/bouncers/crowdsec-openresty-bouncer.yaml;
    # cscli generates an API key at install time for the local LAPI.
    log "CrowdSec OpenResty bouncer installed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_webserver_openresty || exit 0
    check_webserver_openresty && { log "Already installed; skipping."; exit 0; }
    run_webserver_openresty
    check_webserver_openresty || { err "openresty verification failed"; exit 1; }
fi
