# shellcheck shell=bash
# =============================================================================
# 10-profile.sh — Deployment profile selector
# =============================================================================
#
# Runs first (after preflight). Decides which subsequent modules apply.
# Writes PROFILE to state: one of {k8s, docker, bare}.
#
# Profiles:
#   k8s     — Kubernetes node (RKE2 + optional platform stack)
#   docker  — Docker host (reverse-proxy VPS running containers)
#   bare    — Hardened VPS, no container runtime
#
# Standalone execution only prints the current profile and exits.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_profile() { return 0; }

# No canonical "profile file" exists — there's nothing to detect from system
# state. Standalone re-runs prompt afresh.
detect_profile() { return 0; }

configure_profile() {
    local cur
    cur="$(state_get PROFILE)"

    # Map current value back to ask_choice index so it becomes the default.
    local default_idx=1
    case "$cur" in
        k8s)    default_idx=1 ;;
        docker) default_idx=2 ;;
        bare)   default_idx=3 ;;
    esac

    ask_choice "Deployment profile" "$default_idx" \
        "Kubernetes node|RKE2 server or agent; enables platform stack" \
        "Docker host|Reverse-proxy VPS running containers" \
        "Bare VPS|Hardened server with no container runtime"

    case "$REPLY" in
        1) state_set PROFILE k8s ;;
        2) state_set PROFILE docker ;;
        3) state_set PROFILE bare ;;
    esac
}

check_profile() {
    # Nothing to check — profile is pure metadata.
    return 1
}

run_profile() {
    log "Profile: $(state_get PROFILE)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_profile
    configure_profile
    run_profile
fi
