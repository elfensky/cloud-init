# shellcheck shell=bash
# =============================================================================
# 26-sysctl.sh — Kernel modules + sysctl tuning (profile-aware)
# =============================================================================
#
# K8s profile: load CNI-required modules, enable ip_forward, raise inotify
# limits, disable ICMP redirects. Writes /etc/sysctl.d/99-rke2.conf.
#
# Docker and bare profiles: defensive network/kernel hardening, ip_forward=0
# (unless Docker profile, which needs its own handling in 40-docker.sh).
# Writes /etc/sysctl.d/99-hardening.conf.
#
# Both profiles also apply system config: K8s disables swap and raises nofile;
# bare/docker disable core dumps and restrict cron. (Kept here because they
# share the same "this is the kernel/host shape" concern as sysctl.)
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_sysctl() { return 0; }
detect_sysctl()  { return 0; }
configure_sysctl() { return 0; }  # No prompts.
check_sysctl()   { return 1; }   # Re-run is cheap.

_apply_k8s() {
    cat > /etc/modules-load.d/rke2.conf <<'MODEOF'
overlay
br_netfilter
nf_conntrack
xt_set
ip_set
ip_set_hash_ip
ip_set_hash_net
MODEOF

    local mod
    for mod in overlay br_netfilter nf_conntrack xt_set ip_set ip_set_hash_ip ip_set_hash_net; do
        modprobe "$mod" 2>/dev/null || true
    done

    cat > /etc/sysctl.d/99-rke2.conf <<'SYSEOF'
# Required for RKE2/CNI
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.forwarding        = 1
net.ipv6.conf.all.forwarding        = 1

# Inotify limits (pods create many watches)
fs.inotify.max_user_watches  = 524288
fs.inotify.max_user_instances = 8192

# Security
net.ipv4.conf.all.accept_redirects     = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects       = 0
net.ipv4.conf.default.send_redirects   = 0
net.ipv6.conf.all.accept_redirects     = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.tcp_syncookies = 1

# Baseline hardening (host-level, no CNI impact)
kernel.randomize_va_space = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_source_route     = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route     = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
# NOTE: rp_filter intentionally excluded — CNI plugins (Calico, Cilium, Canal)
# require asymmetric routing across veth pairs; strict rp_filter drops pod traffic.
SYSEOF

    # Disable swap for kubelet resource accounting.
    swapoff -a
    sed -i '/\sswap\s/s/^/#/' /etc/fstab
    log "Swap disabled"

    # Raise file descriptor limit for K8s workloads.
    cat > /etc/security/limits.d/99-rke2.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    log "File descriptor limits raised to 1M"

    log "K8s kernel modules loaded, sysctl configured (ip_forward=1)"
}

_apply_standalone() {
    # Docker profile needs ip_forward=1 for bridge networking; bare profile
    # does not. Detect and pick accordingly.
    local profile ip_forward_line
    profile="$(state_get PROFILE)"
    if [[ "$profile" == "docker" ]]; then
        ip_forward_line="net.ipv4.ip_forward = 1  # Docker bridge networking"
    else
        ip_forward_line="net.ipv4.ip_forward = 0  # not a router"
    fi

    cat > /etc/sysctl.d/99-hardening.conf <<SYSEOF
# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcast
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Disable redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Log Martians
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Forwarding (profile-dependent)
${ip_forward_line}

# ASLR
kernel.randomize_va_space = 2
SYSEOF

    # Disable core dumps (sensitive data can leak).
    cat > /etc/security/limits.d/99-disable-core-dumps.conf <<'EOF'
* hard core 0
* soft core 0
EOF

    # Restrict cron to root-only access.
    chmod 600 /etc/crontab 2>/dev/null || true
    chmod 700 /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly 2>/dev/null || true

    log "Standalone hardening applied (profile: ${profile})"
}

run_sysctl() {
    local profile
    profile="$(state_get PROFILE)"
    if [[ "$profile" == "k8s" ]]; then
        _apply_k8s
    else
        _apply_standalone
    fi
    sysctl --system >/dev/null 2>&1 || true
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    run_sysctl
fi
