# shellcheck shell=bash
# =============================================================================
# 71-local-path.sh — Rancher local-path-provisioner as the default StorageClass
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

LOCAL_PATH_VERSION="${LOCAL_PATH_VERSION:-v0.0.30}"
LOCAL_PATH_SHA256="${LOCAL_PATH_SHA256:-fe682186b00400fe7e2b72bae16f63e47a56a6dcc677938c6642139ef670045e}"

applies_local_path() { [[ "$(state_get STEP_rke2_service_COMPLETED)" == "yes" ]]; }

detect_local_path()  { return 0; }

configure_local_path() {
    if ask_yesno "Install local-path-provisioner as default StorageClass?" "y"; then
        state_set PLATFORM_LOCAL_PATH yes
    else
        state_set PLATFORM_LOCAL_PATH no
    fi
}

check_local_path() {
    [[ "$(state_get PLATFORM_LOCAL_PATH no)" == yes ]] || return 0
    kubectl get storageclass local-path >/dev/null 2>&1
}

run_local_path() {
    [[ "$(state_get PLATFORM_LOCAL_PATH)" == yes ]] || { log "local-path disabled."; return 0; }

    local tmp
    tmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN

    curl -fsSL -o "$tmp" \
        "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
    echo "${LOCAL_PATH_SHA256}  $tmp" | sha256sum -c -
    kubectl apply -f "$tmp"
    kubectl patch storageclass local-path \
        -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' \
        >/dev/null 2>&1 || true
    log "local-path-provisioner installed as default StorageClass"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_local_path || exit 0
    export PATH="$PATH:/var/lib/rancher/rke2/bin"
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    configure_local_path
    check_local_path && { log "Already installed; skipping."; exit 0; }
    run_local_path
    check_local_path || { err "local-path verification failed"; exit 1; }
fi
