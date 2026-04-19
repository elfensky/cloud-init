# shellcheck shell=bash
# =============================================================================
# 72-ingress-nginx.sh — ingress-nginx as DaemonSet with Proxy Protocol
# =============================================================================
#
# Runs one pod per worker node, binding hostPort 80/443. The external LB
# points directly at worker IPs; Kubernetes does not allocate a LoadBalancer
# service.
#
# CrowdSec Lua bouncer is injected inline when SECURITY_TOOL=crowdsec AND
# CrowdSec-in-cluster (76-crowdsec-k8s) is installed.
#
# Proxy Protocol ordering warning is preserved — operator must enable PP on
# the LB for 80/443 AFTER this module runs, and NEVER on 6443.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-4.12.1}"
CROWDSEC_CONTROLLER_TAG="${CROWDSEC_CONTROLLER_TAG:-v1.13.2}"
CROWDSEC_CONTROLLER_DIGEST="${CROWDSEC_CONTROLLER_DIGEST:-sha256:4575be24781cad35f8e58437db6a3f492df2a3167fed2b6759a6ff0dc3488d56}"

applies_ingress_nginx() { [[ "$(state_get STEP_rke2_service_COMPLETED)" == "yes" ]]; }

detect_ingress_nginx() { return 0; }

configure_ingress_nginx() {
    if ! ask_yesno "Install ingress-nginx?" "y"; then
        state_set PLATFORM_INGRESS no
        return 0
    fi
    state_set PLATFORM_INGRESS yes

    ask_input "Load balancer private IP (trust PP from this /32 only)" \
        "$(state_get PLATFORM_INGRESS_LB_IP 10.0.0.8)"
    state_set PLATFORM_INGRESS_LB_IP "$REPLY"
}

check_ingress_nginx() {
    [[ "$(state_get PLATFORM_INGRESS no)" == yes ]] || return 0
    helm status -n ingress-nginx ingress-nginx >/dev/null 2>&1
}

run_ingress_nginx() {
    [[ "$(state_get PLATFORM_INGRESS)" == yes ]] || { log "ingress-nginx disabled."; return 0; }

    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
    helm repo update ingress-nginx

    # Worker-label preflight — avoids silent "0 pods scheduled".
    local worker_count
    worker_count="$(kubectl get nodes -l node-role.kubernetes.io/worker=worker --no-headers 2>/dev/null | wc -l)"
    if [[ "$worker_count" -eq 0 ]]; then
        warn "No nodes have label node-role.kubernetes.io/worker=worker"
        warn "Label workers: kubectl label node <name> node-role.kubernetes.io/worker=worker"
        ask_yesno "Continue anyway?" "n" || exit 1
    fi

    local tmp
    tmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN

    local lb_ip cs_enabled bouncer_key
    lb_ip="$(state_get PLATFORM_INGRESS_LB_IP)"
    cs_enabled="$(state_get PLATFORM_CROWDSEC no)"
    bouncer_key="$(state_get CROWDSEC_BOUNCER_KEY)"

    local cs_image="" cs_volumes="" cs_init="" cs_mounts="" cs_cfg=""
    if [[ "$cs_enabled" == "yes" ]]; then
        cs_image=$'\n  image:\n    registry: docker.io\n    image: crowdsecurity/controller\n    tag: "'"$CROWDSEC_CONTROLLER_TAG"$'"\n    digest: "'"$CROWDSEC_CONTROLLER_DIGEST"$'"'
        cs_volumes=$'\n  extraVolumes:\n    - name: crowdsec-bouncer-plugin\n      emptyDir: {}'
        cs_init=$'\n  extraInitContainers:\n    - name: init-clone-crowdsec-bouncer\n      image: crowdsecurity/lua-bouncer-plugin\n      imagePullPolicy: IfNotPresent\n      env:\n        - name: API_URL\n          value: "http://crowdsec-service.crowdsec.svc.cluster.local:8080"\n        - name: API_KEY\n          value: "'"$bouncer_key"$'"\n        - name: BOUNCER_CONFIG\n          value: "/crowdsec/crowdsec-bouncer.conf"\n        - name: APPSEC_URL\n          value: "http://crowdsec-appsec-service.crowdsec.svc.cluster.local:7422"\n        - name: APPSEC_FAILURE_ACTION\n          value: "passthrough"\n      command: ["sh", "-c", "sh /docker_start.sh; mkdir -p /lua_plugins/crowdsec/; cp -R /crowdsec/* /lua_plugins/crowdsec/"]\n      volumeMounts:\n        - name: crowdsec-bouncer-plugin\n          mountPath: /lua_plugins'
        cs_mounts=$'\n  extraVolumeMounts:\n    - name: crowdsec-bouncer-plugin\n      mountPath: /etc/nginx/lua/plugins/crowdsec\n      subPath: crowdsec'
        cs_cfg=$'\n    plugins: "crowdsec"\n    lua-shared-dicts: "crowdsec_cache: 50m"\n    server-snippet: |\n      lua_ssl_trusted_certificate "/etc/ssl/certs/ca-certificates.crt";\n      resolver local=on ipv6=off;'
    fi

    cat > "$tmp" <<EOF
controller:${cs_image}
  kind: DaemonSet
  hostPort:
    enabled: true
  service:
    enabled: false
  nodeSelector:
    node-role.kubernetes.io/worker: "worker"
  config:
    use-proxy-protocol: "true"
    use-forwarded-headers: "true"
    compute-full-forwarded-for: "true"
    proxy-real-ip-cidr: "${lb_ip}/32"
    hide-headers: "Server,X-Powered-By"
    hsts: "true"
    hsts-max-age: "31536000"
    hsts-include-subdomains: "true"
    proxy-body-size: "50m"
    proxy-read-timeout: "120"
    proxy-send-timeout: "120"
    ssl-protocols: "TLSv1.2 TLSv1.3"
    ssl-prefer-server-ciphers: "true"${cs_cfg}
  admissionWebhooks:
    enabled: true
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      namespace: monitoring
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      memory: 256Mi${cs_volumes}${cs_init}${cs_mounts}
EOF

    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx --create-namespace \
        --version "$INGRESS_NGINX_VERSION" \
        -f "$tmp"
    log "ingress-nginx installed"

    echo ""
    warn "═══════════════════════════════════════════════════════════════"
    warn "  NEXT: Enable Proxy Protocol on LB for ports 80/443."
    warn "  DO NOT enable Proxy Protocol on port 6443 — kubectl doesn't speak it."
    warn "═══════════════════════════════════════════════════════════════"
    echo ""
    ask_yesno "Press Y when Proxy Protocol is enabled on the LB (or skip)" "n" || true
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_ingress_nginx || exit 0
    export PATH="$PATH:/var/lib/rancher/rke2/bin"
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    configure_ingress_nginx
    check_ingress_nginx && { log "Already installed; skipping."; exit 0; }
    run_ingress_nginx
    check_ingress_nginx || { err "ingress-nginx verification failed"; exit 1; }
fi
