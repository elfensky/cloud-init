# shellcheck shell=bash
# =============================================================================
# 52-webserver-apache.sh — Install Apache httpd (HTTP-only default vhost)
# =============================================================================
#
# Uses the ppa:ondrej/apache2 PPA (maintained by Ondrej Sury — the same
# maintainer as the ondrej/php and ondrej/nginx PPAs) for the latest 2.4.x
# point releases instead of Ubuntu's somewhat-older default.
#
# Installs apache + writes a minimal HTTP-only default vhost with a
# webroot /.well-known/acme-challenge/ alias. Cert issuance and the TLS
# vhost are handled by step 54-tls-certs (which offers HTTP-01 / DNS-01,
# certbot / acme.sh, and Cloudflare / Route53 / DO plugins).
#
# Note: CrowdSec has no first-class L7 bouncer for Apache. If you picked
# CrowdSec at step 30 you get the host-level iptables bouncer (L3/L4
# blocking). For L7 WAF on top of Apache, layer ModSecurity manually after
# this module completes — out of scope for the wizard.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_webserver_apache() { [[ "$(state_get WEBSERVER_KIND)" == apache ]]; }

detect_webserver_apache() { return 0; }

configure_webserver_apache() {
    info "Installs Apache httpd from ppa:ondrej/apache2 (latest 2.4.x)."
    info "Writes an HTTP-only default vhost; TLS is handled at step 54."
    if ! ask_yesno "Install Apache (ondrej PPA)?" "y"; then
        state_mark_skipped webserver_apache
        return 0
    fi
}

check_webserver_apache() {
    command -v apache2 >/dev/null 2>&1 && systemctl is-active --quiet apache2
}

_install_ondrej_apache_ppa() {
    # software-properties-common is already installed by 23-packages.
    add-apt-repository -y ppa:ondrej/apache2
    apt-get update -qq
}

run_webserver_apache() {
    for pkg in nginx openresty; do
        dpkg -l "$pkg" 2>/dev/null | grep -q '^ii' && apt-get remove -y -qq "$pkg"
    done

    _install_ondrej_apache_ppa
    apt-get install -y -qq apache2

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
    # TLS vhost + cert issuance happen in step 54 (tls-certs).
    log "apache2 installed; default vhost at /etc/apache2/sites-available/000-default.conf"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_webserver_apache || exit 0
    check_webserver_apache && { log "Already installed; skipping."; exit 0; }
    run_webserver_apache
    check_webserver_apache || { err "apache verification failed"; exit 1; }
fi
