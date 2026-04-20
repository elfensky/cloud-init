# shellcheck shell=bash
# =============================================================================
# 54-tls-certs.sh — Let's Encrypt TLS via certbot or acme.sh
# =============================================================================
#
# Runs after 51/52/53 have installed a host web server. Handles ACME
# certificate issuance, writes the TLS server block appropriate to the
# installed webserver (nginx / apache / openresty), and reloads the daemon.
#
# Offered choices:
#
#   Client:
#     certbot (recommended) — EFF's Python client, Ubuntu apt packaged,
#                             systemd timer auto-renews (certbot.timer).
#     acme.sh              — pure shell; broader DNS provider support;
#                             simpler install (curl | sh); installs its
#                             own cron for auto-renewal.
#
#   Challenge:
#     HTTP-01 (default)    — ACME solver proves domain control by serving
#                            a token over HTTP on /.well-known/acme-challenge/.
#                            Needs a publicly resolvable domain and port 80
#                            open to Let's Encrypt. No wildcard certs.
#     DNS-01               — Proof via a TXT record under _acme-challenge.<domain>.
#                            Supports wildcard (*.domain). Doesn't need port 80
#                            open — useful for private hosts or when the
#                            provider firewall blocks inbound.
#
#   DNS provider (DNS-01 only):
#     Cloudflare   — API token with DNS:Edit on the zone.
#     Route53      — AWS access key + secret (IAM user with Route53:* on zone).
#     DigitalOcean — API token with DNS write scope.
#     manual       — Operator creates credential files out-of-band; this
#                    module only installs the tool + plugin.
#
# Skipped when WEBSERVER_DOMAIN is empty (operator chose "no domain" at
# step 50) or WEBSERVER_KIND is "none".
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_tls_certs() {
    local kind
    kind="$(state_get WEBSERVER_KIND)"
    [[ -n "$kind" && "$kind" != "none" ]] \
        && [[ -n "$(state_get WEBSERVER_DOMAIN)" ]]
}

detect_tls_certs() {
    local domain
    domain="$(state_get WEBSERVER_DOMAIN)"
    [[ -z "$domain" ]] && return 0
    if [[ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]] \
       || [[ -f "/root/.acme.sh/$domain/fullchain.cer" ]] \
       || [[ -f "/root/.acme.sh/${domain}_ecc/fullchain.cer" ]]; then
        state_set TLS_CERT_EXISTS yes
    fi
}

configure_tls_certs() {
    local domain
    domain="$(state_get WEBSERVER_DOMAIN)"
    info "Let's Encrypt cert for ${domain} via ACME — the protocol Let's Encrypt"
    info "and others use to prove you own the domain and hand you a cert. Two"
    info "pieces to decide: which ACME client to run, and which 'challenge' type"
    info "(how the CA verifies domain ownership) fits your setup."
    if ! ask_yesno "Set up a Let's Encrypt TLS certificate?" "y"; then
        state_mark_skipped tls_certs
        return 0
    fi

    # --- ACME client ---
    info "ACME client = the program that talks to Let's Encrypt, obtains the cert,"
    info "and auto-renews it every ~60 days. certbot and acme.sh are equivalent"
    info "for most setups; pick certbot unless you specifically need acme.sh's"
    info "broader DNS-provider plugin coverage."
    local tool_default=1
    [[ "$(state_get TLS_TOOL)" == "acme.sh" ]] && tool_default=2
    ask_choice "ACME client" "$tool_default" \
        "certbot (recommended)|EFF's Python client; apt-installable; systemd timer auto-renewal" \
        "acme.sh|Pure shell; broader DNS plugins; installs its own cron"
    case "$REPLY" in
        1) state_set TLS_TOOL certbot ;;
        2) state_set TLS_TOOL acme.sh ;;
    esac

    # --- Challenge type ---
    info "Challenge = how Let's Encrypt verifies you own ${domain} before issuing:"
    info "  HTTP-01: CA hits http://${domain}/.well-known/acme-challenge/<token>."
    info "           Needs the domain already resolving here and port 80 reachable."
    info "           No wildcards. Zero config — pick this unless you can't."
    info "  DNS-01:  You (or your ACME client via a provider API) create a TXT"
    info "           record under _acme-challenge.${domain}. Works without port 80"
    info "           and is the ONLY way to get wildcard (*.${domain}) certs."
    local chal_default=1
    [[ "$(state_get TLS_CHALLENGE)" == "dns-01" ]] && chal_default=2
    ask_choice "ACME challenge" "$chal_default" \
        "HTTP-01|Simpler; needs port 80 reachable; no wildcard certs" \
        "DNS-01|Needs DNS provider API; supports *.domain wildcards"
    case "$REPLY" in
        1) state_set TLS_CHALLENGE http-01 ;;
        2) state_set TLS_CHALLENGE dns-01 ;;
    esac

    # --- DNS provider + credentials (DNS-01 only) ---
    if [[ "$(state_get TLS_CHALLENGE)" == "dns-01" ]]; then
        _configure_dns_provider
        info "A wildcard cert (*.${domain}) covers any one-level subdomain:"
        info "api.${domain}, app.${domain}, foo.${domain} all terminate on the"
        info "same cert. Useful when you host many subdomains; skip if you only"
        info "have one or two — per-subdomain certs are fine and equally secure."
        if ask_yesno "Also issue a wildcard cert for *.${domain}?" "n"; then
            state_set TLS_WILDCARD yes
        else
            state_set TLS_WILDCARD no
        fi
    else
        state_set TLS_WILDCARD no
    fi
}

_configure_dns_provider() {
    local prov_default=1
    case "$(state_get TLS_DNS_PROVIDER)" in
        cloudflare)   prov_default=1 ;;
        route53)      prov_default=2 ;;
        digitalocean) prov_default=3 ;;
        manual)       prov_default=4 ;;
    esac
    ask_choice "DNS provider" "$prov_default" \
        "Cloudflare|API token with DNS:Edit on the zone" \
        "Route53 (AWS)|IAM access key + secret with Route53 write on the zone" \
        "DigitalOcean|Personal access token with DNS write scope" \
        "Manual|Supply credentials out-of-band; this module only installs the plugin"
    case "$REPLY" in
        1) state_set TLS_DNS_PROVIDER cloudflare ;;
        2) state_set TLS_DNS_PROVIDER route53 ;;
        3) state_set TLS_DNS_PROVIDER digitalocean ;;
        4) state_set TLS_DNS_PROVIDER manual ;;
    esac

    case "$(state_get TLS_DNS_PROVIDER)" in
        cloudflare)
            ask_password "Cloudflare API token (DNS:Edit scope on zone; https://dash.cloudflare.com/profile/api-tokens)" 1
            state_set TLS_DNS_CF_TOKEN "$REPLY"
            ;;
        route53)
            info "Create an IAM user in the AWS console with an inline policy granting"
            info "route53:GetChange + route53:ChangeResourceRecordSets on your hosted"
            info "zone (https://console.aws.amazon.com/iam → Users → Add user → Attach"
            info "policy). The access-key pair is shown once at creation time."
            ask_input "AWS access key ID" "$(state_get TLS_DNS_AWS_KEY)"
            state_set TLS_DNS_AWS_KEY "$REPLY"
            ask_password "AWS secret access key" 1
            state_set TLS_DNS_AWS_SECRET "$REPLY"
            ;;
        digitalocean)
            info "Generate a Personal Access Token with the 'dns' write scope at"
            info "https://cloud.digitalocean.com/account/api/tokens — the token is"
            info "shown once, so copy it into the next prompt immediately."
            ask_password "DigitalOcean API token (DNS write scope)" 1
            state_set TLS_DNS_DO_TOKEN "$REPLY"
            ;;
        manual)
            info "Manual mode: create /etc/letsencrypt/credentials (0600) or set"
            info "acme.sh env vars before the cert issuance step in run_."
            ;;
    esac
}

check_tls_certs() {
    local domain
    domain="$(state_get WEBSERVER_DOMAIN)"
    [[ -z "$domain" ]] && return 0
    [[ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]] \
        || [[ -f "/root/.acme.sh/${domain}_ecc/fullchain.cer" ]] \
        || [[ -f "/root/.acme.sh/$domain/fullchain.cer" ]]
}

verify_tls_certs() { check_tls_certs; }

# ---------------------------------------------------------------------------
# certbot
# ---------------------------------------------------------------------------

_cert_paths_certbot() {
    local domain="$1"
    echo "/etc/letsencrypt/live/$domain/fullchain.pem" \
         "/etc/letsencrypt/live/$domain/privkey.pem"
}

_run_certbot() {
    local domain email
    domain="$(state_get WEBSERVER_DOMAIN)"
    email="$(state_get WEBSERVER_EMAIL)"
    [[ -z "$email" ]] && email="admin@${domain}"

    apt-get install -y -qq certbot

    local -a san_args=(-d "$domain")
    [[ "$(state_get TLS_WILDCARD)" == "yes" ]] && san_args+=(-d "*.${domain}")

    if [[ "$(state_get TLS_CHALLENGE)" == "http-01" ]]; then
        mkdir -p /var/www/html
        certbot certonly --webroot -w /var/www/html \
            --non-interactive --agree-tos \
            -m "$email" \
            "${san_args[@]}" \
            || { err "certbot HTTP-01 issuance failed — check DNS and port 80"; return 1; }
    else
        case "$(state_get TLS_DNS_PROVIDER)" in
            cloudflare)
                apt-get install -y -qq python3-certbot-dns-cloudflare
                install -m 0600 /dev/null /etc/letsencrypt/cloudflare.ini
                printf 'dns_cloudflare_api_token = %s\n' "$(state_get TLS_DNS_CF_TOKEN)" \
                    > /etc/letsencrypt/cloudflare.ini
                chmod 0600 /etc/letsencrypt/cloudflare.ini
                certbot certonly --dns-cloudflare \
                    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
                    --non-interactive --agree-tos \
                    -m "$email" \
                    "${san_args[@]}" \
                    || { err "certbot Cloudflare DNS-01 issuance failed"; return 1; }
                ;;
            route53)
                apt-get install -y -qq python3-certbot-dns-route53
                AWS_ACCESS_KEY_ID="$(state_get TLS_DNS_AWS_KEY)" \
                AWS_SECRET_ACCESS_KEY="$(state_get TLS_DNS_AWS_SECRET)" \
                certbot certonly --dns-route53 \
                    --non-interactive --agree-tos \
                    -m "$email" \
                    "${san_args[@]}" \
                    || { err "certbot Route53 DNS-01 issuance failed"; return 1; }
                ;;
            digitalocean)
                apt-get install -y -qq python3-certbot-dns-digitalocean
                install -m 0600 /dev/null /etc/letsencrypt/digitalocean.ini
                printf 'dns_digitalocean_token = %s\n' "$(state_get TLS_DNS_DO_TOKEN)" \
                    > /etc/letsencrypt/digitalocean.ini
                chmod 0600 /etc/letsencrypt/digitalocean.ini
                certbot certonly --dns-digitalocean \
                    --dns-digitalocean-credentials /etc/letsencrypt/digitalocean.ini \
                    --non-interactive --agree-tos \
                    -m "$email" \
                    "${san_args[@]}" \
                    || { err "certbot DigitalOcean DNS-01 issuance failed"; return 1; }
                ;;
            manual)
                warn "Manual DNS provider chosen — skipping automated issuance."
                warn "Run certbot yourself with the plugin of your choice, then re-run"
                warn "  sudo ./main.sh --redo 54-tls-certs"
                warn "so the TLS vhost gets written."
                return 0
                ;;
        esac
    fi

    # certbot.timer handles auto-renewal; package ships it enabled.
    systemctl enable --now certbot.timer 2>/dev/null || true
    log "certbot issued cert for $domain; renewal via certbot.timer"
}

# ---------------------------------------------------------------------------
# acme.sh
# ---------------------------------------------------------------------------

_run_acme_sh() {
    local domain email
    domain="$(state_get WEBSERVER_DOMAIN)"
    email="$(state_get WEBSERVER_EMAIL)"
    [[ -z "$email" ]] && email="admin@${domain}"

    if [[ ! -x /root/.acme.sh/acme.sh ]]; then
        curl --proto '=https' --tlsv1.2 -fsSL https://get.acme.sh \
            | sh -s "email=$email" \
            || { err "acme.sh install failed"; return 1; }
    fi

    local -a san_args=(-d "$domain")
    [[ "$(state_get TLS_WILDCARD)" == "yes" ]] && san_args+=(-d "*.${domain}")

    if [[ "$(state_get TLS_CHALLENGE)" == "http-01" ]]; then
        mkdir -p /var/www/html
        /root/.acme.sh/acme.sh --issue --webroot /var/www/html \
            "${san_args[@]}" \
            || { err "acme.sh HTTP-01 issuance failed"; return 1; }
    else
        case "$(state_get TLS_DNS_PROVIDER)" in
            cloudflare)
                CF_Token="$(state_get TLS_DNS_CF_TOKEN)" \
                /root/.acme.sh/acme.sh --issue --dns dns_cf \
                    "${san_args[@]}" \
                    || { err "acme.sh Cloudflare DNS issuance failed"; return 1; }
                ;;
            route53)
                AWS_ACCESS_KEY_ID="$(state_get TLS_DNS_AWS_KEY)" \
                AWS_SECRET_ACCESS_KEY="$(state_get TLS_DNS_AWS_SECRET)" \
                /root/.acme.sh/acme.sh --issue --dns dns_aws \
                    "${san_args[@]}" \
                    || { err "acme.sh Route53 DNS issuance failed"; return 1; }
                ;;
            digitalocean)
                DO_API_KEY="$(state_get TLS_DNS_DO_TOKEN)" \
                /root/.acme.sh/acme.sh --issue --dns dns_dgon \
                    "${san_args[@]}" \
                    || { err "acme.sh DigitalOcean DNS issuance failed"; return 1; }
                ;;
            manual)
                warn "Manual DNS — skipping automated issuance."
                warn "Set the plugin env var (e.g. CF_Token) and run:"
                warn "  /root/.acme.sh/acme.sh --issue --dns dns_<name> -d $domain"
                return 0
                ;;
        esac
    fi

    # acme.sh installs its own cron on first install. Install the cert into
    # a predictable path under /etc/letsencrypt/ so the webserver configs
    # below can reference one location regardless of the ACME tool.
    mkdir -p "/etc/letsencrypt/live/$domain"
    /root/.acme.sh/acme.sh --install-cert -d "$domain" \
        --fullchain-file "/etc/letsencrypt/live/$domain/fullchain.pem" \
        --key-file       "/etc/letsencrypt/live/$domain/privkey.pem" \
        --reloadcmd      "$(_reload_cmd)"
    log "acme.sh issued cert for $domain; renewal via its built-in cron"
}

_reload_cmd() {
    case "$(state_get WEBSERVER_KIND)" in
        nginx)     echo "systemctl reload nginx" ;;
        apache)    echo "systemctl reload apache2" ;;
        openresty) echo "systemctl reload openresty" ;;
        *)         echo "true" ;;
    esac
}

# ---------------------------------------------------------------------------
# TLS vhost per webserver — appended after issuance.
# ---------------------------------------------------------------------------

_write_tls_vhost() {
    local domain
    domain="$(state_get WEBSERVER_DOMAIN)"
    [[ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]] || {
        warn "No fullchain.pem at /etc/letsencrypt/live/$domain/ — skipping TLS vhost."
        return 0
    }

    case "$(state_get WEBSERVER_KIND)" in
        nginx|openresty) _write_tls_vhost_nginxlike "$domain" ;;
        apache)          _write_tls_vhost_apache "$domain" ;;
    esac
}

_write_tls_vhost_nginxlike() {
    local domain="$1" conf_dir
    if [[ "$(state_get WEBSERVER_KIND)" == "openresty" ]]; then
        conf_dir=/etc/openresty/conf.d
    else
        conf_dir=/etc/nginx/conf.d
    fi
    cat > "${conf_dir}/default-tls.conf" <<EOF
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};
    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    location / { return 200 'Hello from ${domain}\n'; add_header Content-Type text/plain; }
}
EOF
    if [[ "$(state_get WEBSERVER_KIND)" == "openresty" ]]; then
        openresty -t && systemctl reload openresty
    else
        nginx -t && systemctl reload nginx
    fi
}

_write_tls_vhost_apache() {
    local domain="$1"
    a2enmod ssl >/dev/null 2>&1 || true
    cat > /etc/apache2/sites-available/default-ssl.conf <<EOF
<IfModule mod_ssl.c>
<VirtualHost *:443>
    ServerName ${domain}
    DocumentRoot /var/www/html
    SSLEngine on
    SSLCertificateFile      /etc/letsencrypt/live/${domain}/fullchain.pem
    SSLCertificateKeyFile   /etc/letsencrypt/live/${domain}/privkey.pem
    <Directory /var/www/html>
        Require all granted
    </Directory>
</VirtualHost>
</IfModule>
EOF
    a2ensite default-ssl >/dev/null 2>&1 || true
    apache2ctl configtest && systemctl reload apache2
}

run_tls_certs() {
    case "$(state_get TLS_TOOL)" in
        certbot)  _run_certbot ;;
        acme.sh)  _run_acme_sh ;;
        *)        err "Unknown TLS_TOOL"; return 1 ;;
    esac
    _write_tls_vhost
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_tls_certs || { info "No webserver domain set; skipping."; exit 0; }
    detect_tls_certs
    configure_tls_certs
    state_skipped tls_certs && exit 0
    check_tls_certs && { log "Cert already issued; skipping."; exit 0; }
    run_tls_certs
    verify_tls_certs || { err "TLS cert verification failed"; exit 1; }
fi
