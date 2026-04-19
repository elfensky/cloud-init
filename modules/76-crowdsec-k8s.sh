# shellcheck shell=bash
# =============================================================================
# 76-crowdsec-k8s.sh — CrowdSec LAPI + Agent + AppSec in-cluster
# =============================================================================
#
# Deploys the CrowdSec chart into the cluster. Applies automatically when
# SECURITY_TOOL=crowdsec (set by 30-intrusion); no separate y/n prompt.
# That's the same flag that gates the Lua bouncer injection in 72, so both
# stay in sync: picking "crowdsec" at step 30 gives you the host daemon,
# this cluster LAPI/Agent/AppSec, and the Lua bouncer in ingress-nginx.
#
# Ordering: 76 runs AFTER 72 (filename sort). 72 has already injected the
# bouncer init container pointing at crowdsec-service.crowdsec.svc, and
# its retry loop tolerates LAPI not being up yet. When 76 installs LAPI,
# the bouncer reconnects on its next retry.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

CROWDSEC_VERSION="${CROWDSEC_VERSION:-0.22.0}"

applies_crowdsec_k8s() {
    [[ "$(state_get STEP_rke2_service_COMPLETED)" == "yes" ]] \
        && [[ "$(state_get SECURITY_TOOL)" == "crowdsec" ]]
}

detect_crowdsec_k8s() { return 0; }

configure_crowdsec_k8s() {
    # Driven by SECURITY_TOOL from step 30 — no separate y/n here. Generate
    # the bouncer API key if 72 hasn't already, and reuse any host-side
    # enrollment key captured at step 30.
    if [[ -z "$(state_get CROWDSEC_BOUNCER_KEY)" ]]; then
        state_set CROWDSEC_BOUNCER_KEY "$(openssl rand -hex 32)"
    fi
}

check_crowdsec_k8s() {
    helm status -n crowdsec crowdsec >/dev/null 2>&1
}

run_crowdsec_k8s() {
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
    # The bouncer init container in 72-ingress-nginx has a retry loop, so
    # once LAPI's Service is routable, the bouncer connects on its next
    # attempt — no manual re-run of 72 needed.
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
    check_crowdsec_k8s || { err "CrowdSec (k8s) verification failed"; exit 1; }
fi
