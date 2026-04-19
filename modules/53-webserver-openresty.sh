# shellcheck shell=bash
# =============================================================================
# 53-webserver-openresty.sh — OpenResty (nginx + Lua) + optional CrowdSec
#                             Lua bouncer
# =============================================================================
#
# OpenResty is nginx compiled with LuaJIT. Same config syntax as nginx, plus
# the ability to run Lua directly in request handling — which the CrowdSec
# bouncer uses for L7 decisions without a sidecar.
#
# If SECURITY_TOOL=crowdsec, we also install the LuaRocks bouncer package
# (crowdsec-openresty-bouncer) and wire it into the vhost.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_webserver_openresty() { [[ "$(state_get WEBSERVER_KIND)" == openresty ]]; }

detect_webserver_openresty()   { return 0; }
configure_webserver_openresty(){ return 0; }

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

    _issue_letsencrypt_openresty
    log "openresty installed; default vhost at /etc/openresty/conf.d/default.conf"
}

_install_crowdsec_lua_bouncer() {
    apt-get install -y -qq crowdsec-openresty-bouncer 2>/dev/null \
        || warn "crowdsec-openresty-bouncer package not in repo; install manually via luarocks."
    # The package drops /etc/crowdsec/bouncers/crowdsec-openresty-bouncer.yaml;
    # cscli generates an API key at install time for the local LAPI.
    log "CrowdSec OpenResty bouncer installed"
}

_issue_letsencrypt_openresty() {
    local domain email
    domain="$(state_get WEBSERVER_DOMAIN)"
    email="$(state_get WEBSERVER_EMAIL)"
    [[ -z "$domain" ]] && { info "No domain set; skipping Let's Encrypt."; return 0; }
    apt-get install -y -qq certbot
    # webroot challenge: requires /var/www/html to be servable on :80 (which
    # our default vhost does via the acme-challenge location).
    mkdir -p /var/www/html
    certbot certonly --webroot -w /var/www/html \
        --non-interactive --agree-tos \
        -m "${email:-admin@${domain}}" \
        -d "$domain" || { warn "certbot issuance failed — fix DNS and re-run 53-webserver-openresty.sh"; return 0; }

    # Append TLS server block (operator can edit paths afterwards).
    cat > /etc/openresty/conf.d/default-tls.conf <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${domain};
    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / { return 200 'Hello from OpenResty\n'; add_header Content-Type text/plain; }
}
EOF
    openresty -t && systemctl reload openresty
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_webserver_openresty || exit 0
    check_webserver_openresty && { log "Already installed; skipping."; exit 0; }
    run_webserver_openresty
fi
