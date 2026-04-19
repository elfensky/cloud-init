#!/usr/bin/env bash
# =============================================================================
# prepare-rke2-node.sh - Prepare Ubuntu 24.04 node for RKE2 installation
# =============================================================================
# Targets: Hetzner Cloud Ubuntu 24.04 nodes for euraika.net production K8s
# Run as: sudo ./prepare-rke2-node.sh
# Idempotent: safe to re-run
# =============================================================================
set -euo pipefail

# --- Color output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo)"
    exit 1
fi

echo "============================================="
echo "  RKE2 Node Preparation - Ubuntu 24.04"
echo "  $(hostname) | $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "============================================="
echo

# =============================================================================
# 1. SYSTEM UPDATES
# =============================================================================
echo "--- [1/10] System updates ---"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get upgrade -y -qq
log "System packages updated"

# =============================================================================
# 2. ESSENTIAL PACKAGES
# =============================================================================
echo "--- [2/10] Essential packages ---"

PACKAGES=(
    # Security
    fail2ban
    ufw
    unattended-upgrades
    apt-listchanges
    needrestart
    # Networking
    curl
    wget
    socat
    conntrack
    ipvsadm
    ipset
    # Storage (RKE2/Longhorn prerequisites)
    open-iscsi
    nfs-common
    cryptsetup
    # System utilities
    htop
    iotop
    sysstat
    jq
    git
    gnupg
    ca-certificates
    software-properties-common
    bash-completion
    tmux
    # Entropy
    haveged
    # Log management
    logrotate
    # Audit
    auditd
    audispd-plugins
)

apt-get install -y -qq "${PACKAGES[@]}" 2>/dev/null
log "Essential packages installed"

# =============================================================================
# 3. AUTOMATIC SECURITY UPDATES
# =============================================================================
echo "--- [3/10] Automatic security updates ---"

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

# Configure unattended-upgrades
cat > /etc/apt/apt.conf.d/51unattended-upgrades-custom <<'EOF'
// Auto-reboot if required (at 04:00 UTC to minimize impact)
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";

// Remove unused kernel packages after upgrade
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Email notification (if MTA available)
// Unattended-Upgrade::Mail "root";
// Unattended-Upgrade::MailReport "on-change";

// Don't auto-upgrade RKE2 packages (managed separately)
Unattended-Upgrade::Package-Blacklist {
    "rke2-*";
};
EOF

systemctl enable --now unattended-upgrades
log "Automatic security updates configured (reboot at 04:00 UTC if needed)"

# =============================================================================
# 4. SSH HARDENING
# =============================================================================
echo "--- [4/10] SSH hardening ---"

SSHD_CONFIG="/etc/ssh/sshd_config"

# Apply hardening (idempotent via sed)
declare -A SSH_SETTINGS=(
    ["PermitRootLogin"]="no"
    ["PasswordAuthentication"]="no"
    ["PubkeyAuthentication"]="yes"
    ["X11Forwarding"]="no"
    ["MaxAuthTries"]="3"
    ["ClientAliveInterval"]="300"
    ["ClientAliveCountMax"]="2"
    ["AllowTcpForwarding"]="no"
    ["AllowAgentForwarding"]="no"
    ["PermitEmptyPasswords"]="no"
    ["UseDNS"]="no"
)

for key in "${!SSH_SETTINGS[@]}"; do
    value="${SSH_SETTINGS[$key]}"
    if grep -q "^${key}" "$SSHD_CONFIG"; then
        sed -i "s/^${key}.*/${key} ${value}/" "$SSHD_CONFIG"
    elif grep -q "^#${key}" "$SSHD_CONFIG"; then
        sed -i "s/^#${key}.*/${key} ${value}/" "$SSHD_CONFIG"
    else
        echo "${key} ${value}" >> "$SSHD_CONFIG"
    fi
done

# Validate config before restarting
if sshd -t 2>/dev/null; then
    systemctl reload sshd
    log "SSH hardened and reloaded"
else
    err "SSH config validation failed, skipping reload"
fi

# =============================================================================
# 5. FAIL2BAN CONFIGURATION
# =============================================================================
echo "--- [5/10] Fail2ban configuration ---"

cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
banaction = ufw

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
EOF

systemctl enable --now fail2ban
systemctl restart fail2ban
log "Fail2ban configured (SSH: 3 retries, 1h ban)"

# =============================================================================
# 6. FIREWALL (UFW)
# =============================================================================
echo "--- [6/10] Firewall (UFW) ---"

# Reset UFW to defaults if not yet configured
ufw --force reset >/dev/null 2>&1

ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow 22/tcp comment 'SSH'

# RKE2 supervisor API
ufw allow 9345/tcp comment 'RKE2 supervisor API'

# Kubernetes API
ufw allow 6443/tcp comment 'Kubernetes API'

# etcd (cluster internal)
ufw allow 2379:2380/tcp comment 'etcd client and peer'

# Kubelet
ufw allow 10250/tcp comment 'Kubelet API'

# NodePort range
ufw allow 30000:32767/tcp comment 'K8s NodePort services'

# Flannel VXLAN (RKE2 default CNI)
ufw allow 8472/udp comment 'Flannel VXLAN'

# Canal/Calico (if used as CNI)
ufw allow 4789/udp comment 'VXLAN overlay'
ufw allow 179/tcp comment 'BGP (Calico)'

# Metrics server
ufw allow 10251/tcp comment 'kube-scheduler'
ufw allow 10252/tcp comment 'kube-controller-manager'
ufw allow 10257/tcp comment 'kube-controller-manager secure'
ufw allow 10259/tcp comment 'kube-scheduler secure'

# ICMP (ping)
ufw allow proto icmp from any comment 'ICMP ping' 2>/dev/null || true

# Enable UFW
ufw --force enable
log "Firewall configured with RKE2-required ports"

# =============================================================================
# 7. KERNEL MODULES & SYSCTL
# =============================================================================
echo "--- [7/10] Kernel modules and sysctl ---"

# Load required modules
cat > /etc/modules-load.d/rke2.conf <<'EOF'
overlay
br_netfilter
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF

# Load now
for mod in overlay br_netfilter ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack; do
    modprobe "$mod" 2>/dev/null || true
done

# Sysctl for RKE2
cat > /etc/sysctl.d/99-rke2.conf <<'EOF'
# Network bridge and forwarding (required by RKE2)
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv6.conf.all.forwarding        = 1

# Connection tracking
net.netfilter.nf_conntrack_max = 131072

# Increase inotify limits (for many pods)
fs.inotify.max_user_watches  = 524288
fs.inotify.max_user_instances = 8192

# Increase file descriptor limits
fs.file-max = 2097152

# Increase PID limit
kernel.pid_max = 4194304

# Increase ARP cache
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384

# TCP optimizations for K8s
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 8096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1

# Prevent SYN flood
net.ipv4.tcp_syncookies = 1

# Disable ICMP redirects (security)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Log martian packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Increase virtual memory areas (for Elasticsearch, etcd)
vm.max_map_count = 1048576
EOF

sysctl --system >/dev/null 2>&1
log "Kernel modules loaded, sysctl tuned for RKE2"

# =============================================================================
# 8. SERVICES & SYSTEM CONFIG
# =============================================================================
echo "--- [8/10] System services ---"

# Disable swap (required for Kubernetes)
swapoff -a
sed -i '/swap/d' /etc/fstab
log "Swap disabled"

# Enable and start required services
systemctl enable --now iscsid
systemctl enable --now haveged
systemctl enable --now auditd
log "iscsid, haveged, auditd enabled"

# Set timezone to UTC
timedatectl set-timezone UTC
log "Timezone set to UTC"

# Configure NTP (systemd-timesyncd)
systemctl enable --now systemd-timesyncd
log "NTP time sync enabled"

# Increase open file limits
cat > /etc/security/limits.d/99-rke2.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc  unlimited
* hard nproc  unlimited
root soft nofile 1048576
root hard nofile 1048576
EOF
log "File descriptor limits increased"

# Journald: limit disk usage
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-rke2.conf <<'EOF'
[Journal]
SystemMaxUse=1G
SystemMaxFileSize=100M
MaxRetentionSec=7day
Compress=yes
EOF
systemctl restart systemd-journald
log "Journald disk usage limited to 1G"

# =============================================================================
# 9. AUDIT RULES
# =============================================================================
echo "--- [9/10] Audit rules ---"

cat > /etc/audit/rules.d/rke2.rules <<'EOF'
# Monitor RKE2 binary execution
-w /usr/local/bin/rke2 -p x -k rke2
-w /var/lib/rancher/rke2/bin/ -p x -k rke2-bins

# Monitor critical K8s paths
-w /etc/rancher/ -p wa -k rancher-config
-w /var/lib/rancher/ -p wa -k rancher-data

# Monitor user/group changes
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k sudo-changes
-w /etc/sudoers.d/ -p wa -k sudo-changes

# Monitor SSH keys
-w /home/ -p wa -k home-changes

# Cron monitoring
-w /etc/crontab -p wa -k cron
-w /etc/cron.d/ -p wa -k cron
EOF

# Reload audit rules (ignore errors if auditd needs restart)
augenrules --load 2>/dev/null || systemctl restart auditd 2>/dev/null || true
log "Audit rules installed"

# =============================================================================
# 10. CLEANUP & SUMMARY
# =============================================================================
echo "--- [10/10] Cleanup ---"

# Remove unnecessary packages
apt-get autoremove -y -qq
apt-get clean

# Remove cloud-init artifacts if not needed
# (keep it — Hetzner Cloud uses it)

log "Cleanup done"

echo
echo "============================================="
echo "  Node preparation complete!"
echo "============================================="
echo
echo "Summary:"
echo "  - System updated and essential packages installed"
echo "  - Automatic security updates: ON (reboot at 04:00 UTC)"
echo "  - SSH hardened (key-only, no root, max 3 retries)"
echo "  - Fail2ban: SSH jail active (3 retries, 1h ban)"
echo "  - UFW firewall: enabled with RKE2 ports open"
echo "  - Kernel: overlay, br_netfilter, ip_vs modules loaded"
echo "  - Sysctl: tuned for RKE2 (forwarding, conntrack, limits)"
echo "  - Swap: disabled"
echo "  - NTP: synced via systemd-timesyncd"
echo "  - Journald: capped at 1G, 7-day retention"
echo "  - Auditd: monitoring K8s and system changes"
echo "  - File limits: 1M open files"
echo
echo "Next step: Install RKE2"
echo "  curl -sfL https://get.rke2.io | sh -"
echo "  systemctl enable --now rke2-server"
echo
echo "============================================="