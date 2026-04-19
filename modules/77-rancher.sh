# shellcheck shell=bash
# =============================================================================
# 77-rancher.sh — Rancher management UI
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

RANCHER_VERSION="${RANCHER_VERSION:-2.10.3}"

applies_rancher() { [[ "$(state_get STEP_rke2_service_COMPLETED)" == "yes" ]]; }

detect_rancher() { return 0; }

configure_rancher() {
    if ! ask_yesno "Install Rancher (management UI)?" "n"; then
        state_set PLATFORM_RANCHER no
        return 0
    fi
    state_set PLATFORM_RANCHER yes

    ask_input "Rancher hostname (FQDN reachable via your ingress)" \
        "$(state_get PLATFORM_RANCHER_HOST "rancher.$(state_get PLATFORM_CERT_DOMAIN yourdomain.com)")"
    state_set PLATFORM_RANCHER_HOST "$REPLY"

    if [[ "$(state_get PLATFORM_CERTMGR)" == yes ]]; then
        local idx=1
        [[ "$(state_get PLATFORM_RANCHER_ISSUER)" == "letsencrypt-prod" ]] && idx=2
        ask_choice "TLS issuer for Rancher" "$idx" \
            "letsencrypt-staging|Test first" \
            "letsencrypt-prod|Production cert"
        if [[ "$REPLY" == "1" ]]; then
            state_set PLATFORM_RANCHER_ISSUER letsencrypt-staging
        else
            state_set PLATFORM_RANCHER_ISSUER letsencrypt-prod
        fi
    fi

    if [[ -z "$(state_get PLATFORM_RANCHER_PASSWORD)" ]]; then
        info "Bootstrap password (leave blank to auto-generate):"
        ask_password "Password" 0
        local pw="$REPLY"
        [[ -z "$pw" ]] && pw="$(openssl rand -base64 16)" && info "Auto-generated: $pw"
        state_set PLATFORM_RANCHER_PASSWORD "$pw"
    fi

    ask_input "Rancher replicas (match server count for HA)" \
        "$(state_get PLATFORM_RANCHER_REPLICAS 3)"
    state_set PLATFORM_RANCHER_REPLICAS "$REPLY"
}

check_rancher() {
    [[ "$(state_get PLATFORM_RANCHER no)" == yes ]] || return 0
    helm status -n cattle-system rancher >/dev/null 2>&1
}

run_rancher() {
    [[ "$(state_get PLATFORM_RANCHER)" == yes ]] || { log "Rancher disabled."; return 0; }

    helm repo add rancher-stable https://releases.rancher.com/server-charts/stable 2>/dev/null || true
    helm repo update rancher-stable

    local tmp
    tmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN

    cat > "$tmp" <<EOF
hostname: "$(state_get PLATFORM_RANCHER_HOST)"
ingress:
  tls:
    source: secret
  extraAnnotations:
    cert-manager.io/cluster-issuer: "$(state_get PLATFORM_RANCHER_ISSUER letsencrypt-staging)"
replicas: $(state_get PLATFORM_RANCHER_REPLICAS 3)
bootstrapPassword: "$(state_get PLATFORM_RANCHER_PASSWORD)"
resources:
  requests:
    cpu: 250m
    memory: 256Mi
  limits:
    memory: 1Gi
EOF

    helm upgrade --install rancher rancher-stable/rancher \
        --namespace cattle-system --create-namespace \
        --version "$RANCHER_VERSION" \
        -f "$tmp"

    log "Rancher installed"
    log "Rancher: https://$(state_get PLATFORM_RANCHER_HOST) (password: $(state_get PLATFORM_RANCHER_PASSWORD))"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_rancher || exit 0
    export PATH="$PATH:/var/lib/rancher/rke2/bin"
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    configure_rancher
    check_rancher && { log "Already installed; skipping."; exit 0; }
    run_rancher
    check_rancher || { err "Rancher verification failed"; exit 1; }
fi
