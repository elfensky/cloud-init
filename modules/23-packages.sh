# shellcheck shell=bash
# =============================================================================
# 23-packages.sh — apt update/upgrade + base + profile-specific packages
# =============================================================================
#
# K8s profile adds: ipset/conntrack/socat, open-iscsi/nfs-common, auditd.
# These are kube-proxy, kubectl port-forward, persistent-volume, and
# compliance-audit prerequisites respectively.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_packages() { return 0; }
detect_packages()  { return 0; }
configure_packages() { return 0; }  # No prompts; driven entirely by PROFILE.
check_packages()   { return 1; }    # Always re-run apt update safely.

run_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -qq
    log "System updated"

    local common=(
        curl wget ca-certificates gnupg lsb-release
        apt-transport-https software-properties-common
        jq git vim tmux htop unzip net-tools
    )
    local k8s=(
        ipset conntrack socat
        open-iscsi nfs-common
        auditd audispd-plugins
    )

    local profile
    profile="$(state_get PROFILE)"
    if [[ "$profile" == "k8s" ]]; then
        apt-get install -y -qq "${common[@]}" "${k8s[@]}" 2>/dev/null
        systemctl enable iscsid --now 2>/dev/null || true
        log "Common + Kubernetes packages installed"
    else
        apt-get install -y -qq "${common[@]}" 2>/dev/null
        log "Common packages installed"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    run_packages
fi
