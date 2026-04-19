# shellcheck shell=bash
# =============================================================================
# 52-webserver-apache.sh — Install Apache httpd + optional Let's Encrypt cert
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_webserver_apache() { [[ "$(state_get WEBSERVER_KIND)" == apache ]]; }

detect_webserver_apache()   { return 0; }
configure_webserver_apache(){ return 0; }

check_webserver_apache() {
    command -v apache2 >/dev/null 2>&1 && systemctl is-active --quiet apache2
}

run_webserver_apache() {
    apt-get install -y -qq apache2
    for pkg in nginx openresty; do
        dpkg -l "$pkg" 2>/dev/null | grep -q '^ii' && apt-get remove -y -qq "$pkg"
    done

    a2enmod ssl headers rewrite proxy proxy_http proxy_wstunnel >/dev/null

    local domain server_name
    domain="$(state_get WEBSERVER_DOMAIN)"
    server_name="_default_"
    [[ -n "$domain" ]] && server_name="$domain"

    cat > /etc/apache2/sites-available/000-default.conf <<EOF
<VirtualHost *:80>
    ServerName ${server_name}
    DocumentRoot /var/www/html

    <Directory /var/www/html>
        Require all granted
    </Directory>

    # ACME HTTP-01 webroot.
    Alias /.well-known/acme-challenge/ /var/www/html/.well-known/acme-challenge/

    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]
</VirtualHost>
EOF

    apache2ctl configtest && systemctl reload apache2

    _issue_letsencrypt_apache
    log "apache2 installed; default vhost at /etc/apache2/sites-available/000-default.conf"
}

_issue_letsencrypt_apache() {
    local domain email
    domain="$(state_get WEBSERVER_DOMAIN)"
    email="$(state_get WEBSERVER_EMAIL)"
    [[ -z "$domain" ]] && { info "No domain set; skipping Let's Encrypt."; return 0; }
    apt-get install -y -qq certbot python3-certbot-apache
    certbot --apache --non-interactive --agree-tos \
        -m "${email:-admin@${domain}}" \
        -d "$domain" --redirect || warn "certbot issuance failed — fix DNS and re-run 52-webserver-apache.sh"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_webserver_apache || exit 0
    check_webserver_apache && { log "Already installed; skipping."; exit 0; }
    run_webserver_apache
    check_webserver_apache || { err "apache verification failed"; exit 1; }
fi
