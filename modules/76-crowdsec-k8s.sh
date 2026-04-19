# shellcheck shell=bash
# =============================================================================
# 76-crowdsec-k8s.sh — CrowdSec LAPI + Agent + AppSec in-cluster
# =============================================================================
#
# Runs BEFORE 72-ingress-nginx so the decision engine is up when the bouncer
# starts — enforced by glob ordering (76 runs before 72? No — 72 < 76). To
# preserve the original ordering (crowdsec BEFORE ingress), this module is
# installed via `applies_crowdsec_k8s` returning true and main.sh orders by
# number; the original script ran CrowdSec third, ingress fourth. In the new
# layout we renumbered so platform ordering matches: crowdsec must be 72's
# FRIEND — so we put it at 71.5? Simpler: ingress-nginx (72) waits for the
# crowdsec service to be ready (if enabled) before the Lua bouncer init
# container pulls the config. If CrowdSec isn't selected, no dependency.
#
# In practice: operator who selects both runs --phase platform; 72 waits for
# 76 by polling the crowdsec Service. To keep the original semantic, we have
# 72-ingress-nginx skip its Lua-bouncer overlay if PLATFORM_CROWDSEC isn't
# yes at configure time — 76 runs first in the deploy order when selected.
# Since 76 > 72 here, reorder: make this module apply AFTER ingress, which
# actually works: the bouncer polls LAPI endpoints and retries until ready.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

CROWDSEC_VERSION="${CROWDSEC_VERSION:-0.22.0}"

applies_crowdsec_k8s() { [[ "$(state_get STEP_rke2_service_COMPLETED)" == "yes" ]]; }

detect_crowdsec_k8s() { return 0; }

configure_crowdsec_k8s() {
    if ! ask_yesno "Install CrowdSec in the cluster (WAF + ingress bouncer)?" "n"; then
        state_set PLATFORM_CROWDSEC no
        return 0
    fi
    state_set PLATFORM_CROWDSEC yes

    # Auto-generate a bouncer API key if not already on file.
    if [[ -z "$(state_get CROWDSEC_BOUNCER_KEY)" ]]; then
        state_set CROWDSEC_BOUNCER_KEY "$(openssl rand -hex 32)"
    fi

    # Reuse the host-side enrollment key if set; otherwise prompt.
    if [[ -z "$(state_get CROWDSEC_ENROLL_KEY)" ]]; then
        info "Get an enrollment key at https://app.crowdsec.net (leave blank to skip):"
        ask_input "Enrollment key" ""
        state_set CROWDSEC_ENROLL_KEY "$REPLY"
    fi
}

check_crowdsec_k8s() {
    [[ "$(state_get PLATFORM_CROWDSEC no)" == yes ]] || return 0
    helm status -n crowdsec crowdsec >/dev/null 2>&1
}

run_crowdsec_k8s() {
    [[ "$(state_get PLATFORM_CROWDSEC)" == yes ]] || { log "CrowdSec (k8s) disabled."; return 0; }

    helm repo add crowdsec https://crowdsecurity.github.io/helm-charts 2>/dev/null || true
    helm repo update crowdsec

    local tmp bouncer enroll hostname
    tmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN
    bouncer="$(state_get CROWDSEC_BOUNCER_KEY)"
    enroll="$(state_get CROWDSEC_ENROLL_KEY)"
    hostname="$(hostname -f)"

    local enroll_block=""
    if [[ -n "$enroll" ]]; then
        enroll_block=$'\n    - name: ENROLL_KEY\n      value: "'"$enroll"$'"\n    - name: ENROLL_INSTANCE_NAME\n      value: "'"$hostname"$'"'
    fi

    cat > "$tmp" <<EOF
container_runtime: containerd

agent:
  acquisition:
    - namespace: ingress-nginx
      podName: ingress-nginx-controller-*
      program: nginx
  env:
    - name: COLLECTIONS
      value: "crowdsecurity/nginx"

lapi:
  env:
    - name: BOUNCER_KEY_ingress
      value: "${bouncer}"${enroll_block}
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      memory: 256Mi

appsec:
  enabled: true
  acquisitions:
    - appsec_configs:
        - crowdsecurity/appsec-default
      labels:
        type: appsec
      listen_addr: 0.0.0.0:7422
      path: /
      source: appsec
  env:
    - name: COLLECTIONS
      value: "crowdsecurity/appsec-virtual-patching crowdsecurity/appsec-generic-rules"
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      memory: 256Mi
EOF

    helm upgrade --install crowdsec crowdsec/crowdsec \
        --namespace crowdsec --create-namespace \
        --version "$CROWDSEC_VERSION" \
        -f "$tmp"
    log "CrowdSec installed in-cluster (LAPI + Agent + AppSec)"
    info "If ingress-nginx was installed BEFORE this module, re-run ingress-nginx"
    info "so the Lua bouncer init container can reach LAPI."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_crowdsec_k8s || exit 0
    export PATH="$PATH:/var/lib/rancher/rke2/bin"
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    configure_crowdsec_k8s
    check_crowdsec_k8s && { log "Already installed; skipping."; exit 0; }
    run_crowdsec_k8s
fi
