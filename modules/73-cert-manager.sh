# shellcheck shell=bash
# =============================================================================
# 73-cert-manager.sh — cert-manager + letsencrypt-staging / letsencrypt-prod
#                      ClusterIssuers
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.17.1}"

applies_cert_manager() { [[ "$(state_get STEP_rke2_service_COMPLETED)" == "yes" ]]; }

detect_cert_manager() { return 0; }

configure_cert_manager() {
    info "Automates Let's Encrypt cert issuance via ClusterIssuer + HTTP-01 challenge."
    info "Ingress resources get certs by adding a cert-manager.io/cluster-issuer annotation."
    if ! ask_yesno "Install cert-manager (Let's Encrypt automation)?" "y"; then
        state_set PLATFORM_CERTMGR no
        return 0
    fi
    state_set PLATFORM_CERTMGR yes

    info "Let's Encrypt emails this address about renewal failures and"
    info "upcoming expiries. Also counts toward per-account rate limits."
    ask_input "Email address for Let's Encrypt" "$(state_get PLATFORM_CERT_EMAIL)"
    state_set PLATFORM_CERT_EMAIL "$REPLY"

    info "Base domain used to derive default hostnames for the platform stack"
    info "(grafana.<domain>, rancher.<domain>, etc.). Individual modules can"
    info "override their own hostname; this is the fallback."
    ask_input "Domain (base for cert hostnames)" "$(state_get PLATFORM_CERT_DOMAIN yourdomain.com)"
    state_set PLATFORM_CERT_DOMAIN "$REPLY"

    local idx=2
    case "$(state_get PLATFORM_CERT_ISSUERS both)" in
        staging) idx=1 ;;
        both)    idx=2 ;;
        prod)    idx=3 ;;
    esac
    ask_choice "ClusterIssuers to create" "$idx" \
        "Staging only|For testing (untrusted certs)" \
        "Both staging + production|Recommended" \
        "Production only|Real certs (rate-limited)"
    case "$REPLY" in
        1) state_set PLATFORM_CERT_ISSUERS staging ;;
        2) state_set PLATFORM_CERT_ISSUERS both ;;
        3) state_set PLATFORM_CERT_ISSUERS prod ;;
    esac
}

check_cert_manager() {
    [[ "$(state_get PLATFORM_CERTMGR no)" == yes ]] || return 0
    helm status -n cert-manager cert-manager >/dev/null 2>&1 || return 1
    # Helm release green isn't enough — if webhook was slow, the issuer apply
    # in run_ silently failed and downstream Ingress resources never get certs.
    local issuers
    issuers="$(state_get PLATFORM_CERT_ISSUERS)"
    if [[ "$issuers" == "staging" || "$issuers" == "both" ]]; then
        kubectl get clusterissuer letsencrypt-staging >/dev/null 2>&1 || return 1
    fi
    if [[ "$issuers" == "prod" || "$issuers" == "both" ]]; then
        kubectl get clusterissuer letsencrypt-prod >/dev/null 2>&1 || return 1
    fi
    return 0
}

_write_issuer() {
    local name="$1" server="$2" email="$3"
    if ! kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${name}
spec:
  acme:
    server: ${server}
    email: ${email}
    privateKeySecretRef:
      name: ${name}-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
    then
        err "Failed to apply ClusterIssuer ${name}"
        return 1
    fi
    log "ClusterIssuer: ${name}"
}

run_cert_manager() {
    [[ "$(state_get PLATFORM_CERTMGR)" == yes ]] || { log "cert-manager disabled."; return 0; }

    helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
    helm repo update jetstack

    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager --create-namespace \
        --version "$CERT_MANAGER_VERSION" \
        --set crds.enabled=true \
        --set resources.requests.cpu=50m \
        --set resources.requests.memory=64Mi \
        --wait --timeout 300s
    log "cert-manager installed"

    # The webhook's APIService takes a bit to register even after the
    # deployment is available — the previous fixed `sleep 10` was optimistic
    # on slow nodes, so ClusterIssuer applies raced and silently failed.
    kubectl wait --for=condition=available --timeout=300s \
        deployment/cert-manager-webhook -n cert-manager

    local email issuers
    email="$(state_get PLATFORM_CERT_EMAIL)"
    issuers="$(state_get PLATFORM_CERT_ISSUERS)"

    if [[ "$issuers" == "staging" || "$issuers" == "both" ]]; then
        _write_issuer "letsencrypt-staging" "https://acme-staging-v02.api.letsencrypt.org/directory" "$email" \
            || return 1
    fi
    if [[ "$issuers" == "prod" || "$issuers" == "both" ]]; then
        _write_issuer "letsencrypt-prod" "https://acme-v02.api.letsencrypt.org/directory" "$email" \
            || return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_cert_manager || exit 0
    export PATH="$PATH:/var/lib/rancher/rke2/bin"
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    configure_cert_manager
    check_cert_manager && { log "Already installed; skipping."; exit 0; }
    run_cert_manager
    check_cert_manager || { err "cert-manager verification failed"; exit 1; }
fi
