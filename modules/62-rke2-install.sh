# shellcheck shell=bash
# =============================================================================
# 62-rke2-install.sh — Install K8s prereqs + download RKE2 + run installer
# =============================================================================
#
# Writes the CNI-required sysctl file, loads kernel modules, installs K8s
# apt packages (ipset/conntrack/socat/open-iscsi/nfs-common/auditd), then
# downloads and executes the pinned RKE2 installer.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_rke2_install() { [[ "$(state_get STEP_rke2_SELECTED)" == "yes" ]]; }

detect_rke2_install() { return 0; }

configure_rke2_install() {
    info "Installs K8s prereqs (ipset/conntrack/socat/...), writes the"
    info "CNI sysctl/module bundle, then runs the sha256-verified RKE2 installer."
    if ! ask_yesno "Download and install the RKE2 binary?" "y"; then
        state_mark_skipped rke2_install
        return 0
    fi
}

check_rke2_install() {
    [[ -x /usr/local/bin/rke2 ]]
}

verify_rke2_install() {
    # Verify the load-bearing keys from /etc/sysctl.d/99-rke2.conf — on container
    # hosts / kernels with locked sysctls, some keys may fail to apply while
    # others succeed. The rp_filter=0 CNI carve-out in particular is required
    # for Calico/Cilium asymmetric-routing; missing it breaks pod-to-pod traffic
    # at runtime with the k8s API still reporting nodes as Ready.
    [[ -x /usr/local/bin/rke2 ]] || return 1
    [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]] || return 1
    [[ "$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)" == "1" ]] || return 1
    [[ "$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)" == "0" ]] || return 1
    lsmod 2>/dev/null | grep -q '^br_netfilter' || return 1
    return 0
}

_install_k8s_sysctl_and_modules() {
    cat > /etc/modules-load.d/rke2.conf <<'EOF'
overlay
br_netfilter
nf_conntrack
xt_set
ip_set
ip_set_hash_ip
ip_set_hash_net
EOF
    local m
    for m in overlay br_netfilter nf_conntrack xt_set ip_set ip_set_hash_ip ip_set_hash_net; do
        modprobe "$m" 2>/dev/null || true
    done

    cat > /etc/sysctl.d/99-rke2.conf <<'EOF'
# Required for RKE2/CNI
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.forwarding        = 1
net.ipv6.conf.all.forwarding        = 1

# Inotify limits (pods create many watches)
fs.inotify.max_user_watches  = 524288
fs.inotify.max_user_instances = 8192

# ICMP redirect security
net.ipv4.conf.all.accept_redirects     = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects       = 0
net.ipv4.conf.default.send_redirects   = 0
net.ipv6.conf.all.accept_redirects     = 0
net.ipv6.conf.default.accept_redirects = 0

# NOTE: rp_filter removed here — CNI plugins (Calico, Cilium, Canal) require
# asymmetric routing across veth pairs; strict rp_filter drops pod traffic.
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
    sysctl --system >/dev/null 2>&1 || true

    # Disable swap for kubelet resource accounting.
    swapoff -a || true
    sed -i '/\sswap\s/s/^/#/' /etc/fstab

    # Raise file descriptor limit.
    cat > /etc/security/limits.d/99-rke2.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
}

_install_k8s_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq \
        ipset conntrack socat \
        open-iscsi nfs-common \
        auditd audispd-plugins
    systemctl enable iscsid --now 2>/dev/null || true
}

run_rke2_install() {
    _install_k8s_packages
    _install_k8s_sysctl_and_modules

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
    verify_rke2_install || { err "RKE2 install verification failed"; exit 1; }
fi
