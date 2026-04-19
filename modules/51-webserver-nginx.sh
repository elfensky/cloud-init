# shellcheck shell=bash
# =============================================================================
# 51-webserver-nginx.sh — Install nginx + optional Let's Encrypt cert
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_webserver_nginx() { [[ "$(state_get WEBSERVER_KIND)" == nginx ]]; }

detect_webserver_nginx()   { return 0; }
configure_webserver_nginx(){ return 0; }

check_webserver_nginx() {
    command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx
}

run_webserver_nginx() {
    apt-get install -y -qq nginx
    # Remove any other web server conflicting on :80/:443 — operator already
    # confirmed the choice in 50-webserver-choice.
    for pkg in apache2 openresty; do
        dpkg -l "$pkg" 2>/dev/null | grep -q '^ii' && apt-get remove -y -qq "$pkg"
    done

    local domain
    domain="$(state_get WEBSERVER_DOMAIN)"
    local server_name="_"
    [[ -n "$domain" ]] && server_name="$domain"

    # Default vhost: minimal, TLS-ready. Listens on both public and (if present)
    # private networks — admin endpoints can be exposed internally.
    cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${server_name};

    # ACME HTTP-01 challenge support (certbot webroot).
    location /.well-known/acme-challenge/ { root /var/www/html; }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx

    _issue_letsencrypt_nginx
    log "nginx installed; default vhost at /etc/nginx/sites-available/default"
}

_issue_letsencrypt_nginx() {
    local domain email
    domain="$(state_get WEBSERVER_DOMAIN)"
    email="$(state_get WEBSERVER_EMAIL)"
    [[ -z "$domain" ]] && { info "No domain set; skipping Let's Encrypt."; return 0; }
    apt-get install -y -qq certbot python3-certbot-nginx
    certbot --nginx --non-interactive --agree-tos \
        -m "${email:-admin@${domain}}" \
        -d "$domain" --redirect || warn "certbot issuance failed — fix DNS and re-run 51-webserver-nginx.sh"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_webserver_nginx || exit 0
    check_webserver_nginx && { log "Already installed; skipping."; exit 0; }
    run_webserver_nginx
    check_webserver_nginx || { err "nginx verification failed"; exit 1; }
fi
