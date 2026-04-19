# shellcheck shell=bash
# =============================================================================
# 70-helm.sh — Install Helm binary (pin to a known version)
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

HELM_VERSION="${HELM_VERSION:-v3.17.1}"

applies_helm() { [[ "$(state_get STEP_rke2_service_COMPLETED)" == "yes" ]]; }

detect_helm() { return 0; }

configure_helm() {
    info "Installs the Helm 3 CLI, pinned to a known-good version."
    info "Required by every platform module from 71 onward."
    if ! ask_yesno "Install the Helm CLI?" "y"; then
        state_mark_skipped helm
        return 0
    fi
}

check_helm() {
    command -v helm >/dev/null 2>&1
}

run_helm() {
    if check_helm; then
        log "Helm already installed: $(helm version --short 2>/dev/null)"
        return 0
    fi
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
        | DESIRED_VERSION="$HELM_VERSION" bash
    log "Helm installed: $(helm version --short 2>/dev/null)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_helm || exit 0
    check_helm && { log "Already installed; skipping."; exit 0; }
    run_helm
    check_helm || { err "Helm verification failed"; exit 1; }
fi
