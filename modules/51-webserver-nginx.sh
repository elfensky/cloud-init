# shellcheck shell=bash
# =============================================================================
# 51-webserver-nginx.sh — Install upstream nginx + optional Let's Encrypt cert
# =============================================================================
#
# Uses the official nginx.org apt repository (stable channel) instead of
# Ubuntu's packaged nginx. Rationale: nginx.org ships newer releases with
# current HTTP/3, QUIC, and performance fixes.
#
# Note: the upstream nginx packages DO NOT include the Lua module, so the
# CrowdSec nginx Lua bouncer (crowdsec-nginx-bouncer) cannot be wired in on
# this path. If you selected CrowdSec at step 30 AND want L7 enforcement
# (not just the host iptables bouncer), pick OpenResty at step 50 instead —
# that module installs the full Lua bouncer stack. Here, we rely on the
# host-level firewall bouncer from 30-intrusion for L3/L4 protection.
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

_install_nginx_org_repo() {
    local codename
    codename="$(lsb_release -cs)"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor -o /etc/apt/keyrings/nginx.gpg
    chmod a+r /etc/apt/keyrings/nginx.gpg

    cat > /etc/apt/sources.list.d/nginx.list <<EOF
deb [signed-by=/etc/apt/keyrings/nginx.gpg] http://nginx.org/packages/ubuntu ${codename} nginx
EOF

    # Pin so nginx.org wins over Ubuntu's universe package for `nginx`. Without
    # this, an `apt upgrade` could pull the distro version back in.
    cat > /etc/apt/preferences.d/99nginx <<'EOF'
Package: *
Pin: origin nginx.org
Pin-Priority: 900
EOF

    apt-get update -qq
}

run_webserver_nginx() {
    # Remove any other web server conflicting on :80/:443. If Ubuntu's nginx
    # was already installed (e.g. from a prior run on this repo), we remove
    # it too so the nginx.org package installs cleanly without version-skew
    # complaints.
    for pkg in apache2 openresty; do
        dpkg -l "$pkg" 2>/dev/null | grep -q '^ii' && apt-get remove -y -qq "$pkg"
    done
    # If an Ubuntu-origin nginx is installed, drop it so apt re-resolves
    # from nginx.org after we add the repo.
    if dpkg -l nginx 2>/dev/null | grep -q '^ii'; then
        local origin
        origin="$(apt-cache policy nginx 2>/dev/null | awk '/Installed:/{v=$2} /^ [0-9]/{if (matched==0 && $0 ~ v) {getline; print; matched=1}}' | awk '{print $3}')"
        if [[ -z "$origin" || "$origin" != *"nginx.org"* ]]; then
            apt-get remove -y -qq nginx nginx-common 2>/dev/null || true
        fi
    fi

    _install_nginx_org_repo
    apt-get install -y -qq nginx

    local domain
    domain="$(state_get WEBSERVER_DOMAIN)"
    local server_name="_"
    [[ -n "$domain" ]] && server_name="$domain"

    # nginx.org's default layout uses /etc/nginx/conf.d/ (no sites-available/).
    # Write the default vhost there. Upstream ships a default.conf we replace.
    cat > /etc/nginx/conf.d/default.conf <<EOF
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

    nginx -t && systemctl enable --now nginx && systemctl reload nginx

    _issue_letsencrypt_nginx
    log "nginx (upstream nginx.org) installed; default vhost at /etc/nginx/conf.d/default.conf"
}

_issue_letsencrypt_nginx() {
    local domain email
    domain="$(state_get WEBSERVER_DOMAIN)"
    email="$(state_get WEBSERVER_EMAIL)"
    [[ -z "$domain" ]] && { info "No domain set; skipping Let's Encrypt."; return 0; }
    # Use certbot's webroot plugin — the python3-certbot-nginx plugin from
    # Ubuntu doesn't play well with upstream nginx's packaging layout.
    apt-get install -y -qq certbot
    mkdir -p /var/www/html
    certbot certonly --webroot -w /var/www/html \
        --non-interactive --agree-tos \
        -m "${email:-admin@${domain}}" \
        -d "$domain" || { warn "certbot issuance failed — fix DNS and re-run 51-webserver-nginx.sh"; return 0; }

    # Append TLS server block. Operator can edit /etc/nginx/conf.d/* to taste.
    cat > /etc/nginx/conf.d/default-tls.conf <<EOF
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};
    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / { return 200 'Hello from nginx\n'; add_header Content-Type text/plain; }
}
EOF
    nginx -t && systemctl reload nginx
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_webserver_nginx || exit 0
    check_webserver_nginx && { log "Already installed; skipping."; exit 0; }
    run_webserver_nginx
    check_webserver_nginx || { err "nginx verification failed"; exit 1; }
fi
