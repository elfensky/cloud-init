# shellcheck shell=bash
# =============================================================================
# 62-rke2-install.sh — Download the RKE2 installer, verify sha256, run it
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_rke2_install() { [[ "$(state_get PROFILE)" == k8s ]]; }

detect_rke2_install()   { return 0; }
configure_rke2_install(){ return 0; }

check_rke2_install() {
    [[ -x /usr/local/bin/rke2 ]]
}

run_rke2_install() {
    local -a args=()
    [[ "$(state_get RKE2_ROLE)" == "worker" ]] && args+=("INSTALL_RKE2_TYPE=agent")
    local channel
    channel="$(state_get RKE2_CHANNEL)"
    [[ -n "$channel" ]] && args+=("INSTALL_RKE2_CHANNEL=${channel}")

    local installer
    installer="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$installer'" RETURN
    curl --proto '=https' --tlsv1.2 -sfL https://get.rke2.io -o "$installer"
    log "Installer sha256: $(sha256sum "$installer" | cut -d' ' -f1)"

    if [[ ${#args[@]} -gt 0 ]]; then
        env "${args[@]}" bash "$installer"
    else
        bash "$installer"
    fi
    log "RKE2 installed: $(/usr/local/bin/rke2 --version 2>/dev/null | head -1 || echo unknown)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_rke2_install || exit 0
    check_rke2_install && { log "RKE2 already installed; skipping."; exit 0; }
    run_rke2_install
fi
