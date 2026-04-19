# shellcheck shell=bash
# =============================================================================
# 72-ingress-nginx.sh — ingress-nginx as DaemonSet with Proxy Protocol
# =============================================================================
#
# Runs one pod per worker node, binding hostPort 80/443. The external LB
# points directly at worker IPs; Kubernetes does not allocate a LoadBalancer
# service.
#
# The CrowdSec Lua bouncer is injected inline when SECURITY_TOOL=crowdsec
# (set by step 30-intrusion, which runs well before this module). That one
# flag is the single switch: picking "crowdsec" at step 30 gives you the
# host daemon, cluster LAPI (via module 76), and this Lua bouncer at L7.
# 76's applies_ is gated on the same flag — they stay in sync without
# ordering games.
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
    info "Cluster-wide L7 ingress as a DaemonSet on worker nodes (hostPort 80/443)."
    info "Injects the CrowdSec Lua bouncer automatically when step 30 chose CrowdSec."
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

    local lb_ip cs_enabled
    lb_ip="$(state_get PLATFORM_INGRESS_LB_IP)"
    # SECURITY_TOOL=crowdsec (set by 30-intrusion) drives both the in-cluster
    # LAPI install (76-crowdsec-k8s) and this L7 bouncer injection. Single
    # switch, no ordering coupling.
    cs_enabled="no"
    [[ "$(state_get SECURITY_TOOL)" == "crowdsec" ]] && cs_enabled="yes"

    # Bouncer key resolution: state.env (this run) → existing k8s Secret
    # (recovery after 99-finalize wiped state.env) → freshly generated.
    # The Secret in ingress-nginx namespace is the canonical store, so 76
    # and this module always agree — no drift on --redo after a clean run.
    if [[ "$cs_enabled" == "yes" ]]; then
        if [[ -z "$(state_get CROWDSEC_BOUNCER_KEY)" ]]; then
            local existing
            existing="$(kubectl -n ingress-nginx get secret crowdsec-bouncer-key \
                -o jsonpath='{.data.key}' 2>/dev/null | base64 -d 2>/dev/null || true)"
            if [[ -n "$existing" ]]; then
                state_set CROWDSEC_BOUNCER_KEY "$existing"
                log "Reused bouncer key from ingress-nginx/crowdsec-bouncer-key Secret"
            else
                state_set CROWDSEC_BOUNCER_KEY "$(openssl rand -hex 32)"
            fi
        fi
        # Upsert the namespace + Secret so the init container can reference
        # it via secretKeyRef instead of embedding the literal in Helm values.
        kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        kubectl create secret generic crowdsec-bouncer-key \
            --namespace ingress-nginx \
            --from-literal=key="$(state_get CROWDSEC_BOUNCER_KEY)" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    fi

    local cs_image="" cs_volumes="" cs_init="" cs_mounts="" cs_cfg=""
    if [[ "$cs_enabled" == "yes" ]]; then
        cs_image=$'\n  image:\n    registry: docker.io\n    image: crowdsecurity/controller\n    tag: "'"$CROWDSEC_CONTROLLER_TAG"$'"\n    digest: "'"$CROWDSEC_CONTROLLER_DIGEST"$'"'
        cs_volumes=$'\n  extraVolumes:\n    - name: crowdsec-bouncer-plugin\n      emptyDir: {}'
        # API_KEY now comes from the Secret via secretKeyRef. If an operator
        # re-runs 72 after a state.env wipe, the init container keeps getting
        # the same key (the Secret is unchanged), and 76 reads the same value.
        cs_init=$'\n  extraInitContainers:\n    - name: init-clone-crowdsec-bouncer\n      image: crowdsecurity/lua-bouncer-plugin\n      imagePullPolicy: IfNotPresent\n      env:\n        - name: API_URL\n          value: "http://crowdsec-service.crowdsec.svc.cluster.local:8080"\n        - name: API_KEY\n          valueFrom:\n            secretKeyRef:\n              name: crowdsec-bouncer-key\n              key: key\n        - name: BOUNCER_CONFIG\n          value: "/crowdsec/crowdsec-bouncer.conf"\n        - name: APPSEC_URL\n          value: "http://crowdsec-appsec-service.crowdsec.svc.cluster.local:7422"\n        - name: APPSEC_FAILURE_ACTION\n          value: "passthrough"\n      command: ["sh", "-c", "sh /docker_start.sh; mkdir -p /lua_plugins/crowdsec/; cp -R /crowdsec/* /lua_plugins/crowdsec/"]\n      volumeMounts:\n        - name: crowdsec-bouncer-plugin\n          mountPath: /lua_plugins'
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
