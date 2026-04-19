# shellcheck shell=bash
# =============================================================================
# 63-rke2-service.sh — Enable, start, and verify the RKE2 systemd service
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_rke2_service() { [[ "$(state_get STEP_rke2_SELECTED)" == "yes" ]]; }

detect_rke2_service()   { return 0; }
configure_rke2_service(){ return 0; }

check_rke2_service() {
    local svc
    svc="$(_rke2_service_name)"
    systemctl is-active --quiet "$svc"
}

_rke2_service_name() {
    if [[ "$(state_get RKE2_ROLE)" == "worker" ]]; then
        echo "rke2-agent"
    else
        echo "rke2-server"
    fi
}

_check_node_ready() {
    local node="$1" status
    status="$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    [[ "$status" == "True" ]]
}

_check_system_pods() {
    local total not_ready
    total="$(kubectl get pods -n kube-system --no-headers 2>/dev/null | wc -l)"
    (( total > 0 )) || return 1
    not_ready="$(kubectl get pods -n kube-system --no-headers 2>/dev/null \
        | grep -cvE 'Running|Completed|Succeeded')" || true
    (( not_ready == 0 ))
}

_check_agent_healthy() {
    systemctl is-active --quiet rke2-agent || return 1
    ! journalctl -u rke2-agent --since "30 seconds ago" --no-pager -q 2>/dev/null \
        | grep -qiE 'fatal|panic'
}

run_rke2_service() {
    local svc role hostname
    svc="$(_rke2_service_name)"
    role="$(state_get RKE2_ROLE)"
    hostname="$(state_get HOSTNAME_FQDN "$(hostname)")"

    systemctl enable "$svc"
    info "Starting ${svc}... (this may take several minutes)"
    if ! timeout 300 systemctl start "$svc"; then
        err "${svc} failed to start within 300s"
        err "Check: journalctl -u ${svc} --no-pager -n 50"
        exit 1
    fi
    log "${svc} started"

    if [[ "$role" != "worker" ]]; then
        export PATH="$PATH:/var/lib/rancher/rke2/bin"
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    fi

    # Non-fatal readiness polls — these are informational, not gates.
    case "$role" in
        bootstrap)
            wait_for "kubectl connectivity"     60  5  kubectl get nodes || true
            wait_for "${hostname} Ready"       120 10  _check_node_ready "$hostname" || true
            wait_for "kube-system pods running" 180 15  _check_system_pods || true
            ;;
        server)
            wait_for "kubectl connectivity"     90  5  kubectl get nodes || true
            wait_for "${hostname} Ready"       120 10  _check_node_ready "$hostname" || true
            ;;
        worker)
            wait_for "rke2-agent stability"     30 10  _check_agent_healthy || true
            ;;
    esac

    [[ "$role" != "worker" ]] && kubectl get nodes -o wide 2>/dev/null || true
}

verify_rke2_service() {
    local svc
    svc="$(_rke2_service_name)"
    systemctl is-active --quiet "$svc" || return 1
    # Servers also need a kubectl handshake; worker verification ends at
    # service-active because there's no kubeconfig locally.
    if [[ "$(state_get RKE2_ROLE)" != "worker" ]]; then
        export PATH="$PATH:/var/lib/rancher/rke2/bin"
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        kubectl get nodes >/dev/null 2>&1 || return 1
    fi
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_rke2_service || exit 0
    run_rke2_service
    verify_rke2_service || { err "RKE2 service verification failed"; exit 1; }
fi
