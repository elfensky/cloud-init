#!/usr/bin/env bash
# =============================================================================
# prepare-rke2-node.sh — RKE2 Base Image Preparation for Hetzner Cloud
# CNI: Calico | kube-proxy: iptables (default) | OS: Ubuntu 24.04
#
# Network model:
#   eth0   — public interface  (UFW: deny all except SSH)
#   ens10  — private interface (UFW: allow all, trusted inter-node traffic)
#
# Run as root: sudo ./prepare-rke2-node.sh
# Idempotent:  safe to re-run without side effects.
# After running, shut down and snapshot from Hetzner console.
#
# IMPORTANT: Verify interface names with 'ip a' before running.
# =============================================================================

set -euo pipefail

# --- Configuration (edit these) ---
PRIVATE_IFACE="ens10"
SSH_PORT="22"

# --- Color output ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo)"
    exit 1
fi

# --- Verify interfaces exist ---
if ! ip link show "${PRIVATE_IFACE}" &>/dev/null; then
    err "Private interface '${PRIVATE_IFACE}' not found. Check with 'ip a' and update PRIVATE_IFACE."
    exit 1
fi

if ! ip link show eth0 &>/dev/null; then
    err "Public interface 'eth0' not found. Check with 'ip a'."
    exit 1
fi

echo "============================================="
echo "  RKE2 Node Preparation — Ubuntu 24.04"
echo "  Host: $(hostname) | $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "  Public:  eth0"
echo "  Private: ${PRIVATE_IFACE}"
echo "  SSH:     port ${SSH_PORT}"
echo "============================================="
echo

# =============================================================================
# 1. ESSENTIAL PACKAGES
# =============================================================================
echo "--- [1/8] Essential packages ---"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    curl wget ca-certificates gnupg \
    ipset conntrack socat \
    open-iscsi nfs-common \
    fail2ban \
    auditd audispd-plugins \
    jq 2>/dev/null

systemctl enable iscsid --now 2>/dev/null
log "Packages installed, iscsid enabled"

# =============================================================================
# 2. SSH HARDENING
# =============================================================================
echo "--- [2/8] SSH hardening ---"

SSHD_CONFIG="/etc/ssh/sshd_config"

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

# Ubuntu 24.04 uses 'ssh', older versions use 'sshd'
SSH_SERVICE="ssh"
if ! systemctl list-units --type=service --all | grep -q "ssh.service"; then
    SSH_SERVICE="sshd"
fi

if sshd -t 2>/dev/null; then
    systemctl reload "${SSH_SERVICE}"
    log "SSH hardened (key-only, no root, max 3 retries)"
else
    err "SSH config validation failed — skipping reload"
fi

# =============================================================================
# 3. FAIL2BAN
# =============================================================================
echo "--- [3/8] Fail2ban ---"

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
banaction = ufw

[sshd]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 3600
EOF

systemctl enable fail2ban --now 2>/dev/null
systemctl restart fail2ban
log "Fail2ban active (SSH: 3 retries, 1h ban)"

# =============================================================================
# 4. UFW FIREWALL
# =============================================================================
echo "--- [4/8] UFW firewall ---"

# Reset to clean state (idempotent — always produces the same result)
ufw --force reset >/dev/null 2>&1

# Default policy: deny incoming, allow outgoing
ufw default deny incoming
ufw default allow outgoing

# Public interface: SSH only
ufw allow in on eth0 to any port "${SSH_PORT}" proto tcp comment 'SSH'

# Private interface: trust completely (all inter-node RKE2/Calico traffic)
ufw allow in on "${PRIVATE_IFACE}" comment 'Private network'

ufw --force enable
log "UFW enabled — public: SSH only, private: all traffic allowed"

# =============================================================================
# 5. KERNEL MODULES & SYSCTL
# =============================================================================
echo "--- [5/8] Kernel modules & sysctl ---"

# Persistent module loading (overwrites cleanly on re-run)
cat > /etc/modules-load.d/rke2.conf <<'EOF'
overlay
br_netfilter
nf_conntrack
xt_set
ip_set
ip_set_hash_ip
ip_set_hash_net
EOF

# Load modules for current session
for mod in overlay br_netfilter nf_conntrack xt_set ip_set ip_set_hash_ip ip_set_hash_net; do
    modprobe "$mod" 2>/dev/null || true
done

# Sysctl tuning (overwrites cleanly on re-run)
cat > /etc/sysctl.d/99-rke2.conf <<'EOF'
# Required for RKE2/Calico
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.forwarding        = 1
net.ipv6.conf.all.forwarding        = 1

# Inotify limits (pods create many watches)
fs.inotify.max_user_watches  = 524288
fs.inotify.max_user_instances = 8192

# Security: reject ICMP redirects (prevent MITM via route injection)
net.ipv4.conf.all.accept_redirects     = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects       = 0
net.ipv4.conf.default.send_redirects   = 0
net.ipv6.conf.all.accept_redirects     = 0
net.ipv6.conf.default.accept_redirects = 0

# Security: SYN flood protection
net.ipv4.tcp_syncookies = 1
EOF

sysctl --system >/dev/null 2>&1
log "Kernel modules loaded, sysctl configured"

# =============================================================================
# 6. SYSTEM CONFIGURATION
# =============================================================================
echo "--- [6/8] System configuration ---"

# Disable swap (required by Kubernetes)
swapoff -a
sed -i '/\sswap\s/s/^/#/' /etc/fstab
log "Swap disabled"

# File descriptor limits (overwrites cleanly on re-run)
cat > /etc/security/limits.d/99-rke2.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
log "File descriptor limits raised"

# Journald: cap disk usage (overwrites cleanly on re-run)
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-rke2.conf <<'EOF'
[Journal]
SystemMaxUse=1G
SystemMaxFileSize=100M
MaxRetentionSec=7day
Compress=yes
EOF
systemctl restart systemd-journald
log "Journald capped at 1G / 7-day retention"

# Timezone and NTP
timedatectl set-timezone UTC
systemctl enable systemd-timesyncd --now 2>/dev/null
log "Timezone UTC, NTP enabled"

# =============================================================================
# 7. AUDIT RULES
# =============================================================================
echo "--- [7/8] Audit rules ---"

# Overwrites cleanly on re-run
cat > /etc/audit/rules.d/rke2.rules <<'EOF'
# RKE2 binaries
-w /usr/local/bin/rke2 -p x -k rke2
-w /var/lib/rancher/rke2/bin/ -p x -k rke2-bins

# RKE2/Rancher config and data
-w /etc/rancher/ -p wa -k rancher-config
-w /var/lib/rancher/ -p wa -k rancher-data

# Identity and access
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k sudo-changes
-w /etc/sudoers.d/ -p wa -k sudo-changes

# SSH keys
-w /home/ -p wa -k home-changes

# Cron
-w /etc/crontab -p wa -k cron
-w /etc/cron.d/ -p wa -k cron
EOF

systemctl enable auditd --now 2>/dev/null
augenrules --load 2>/dev/null || systemctl restart auditd 2>/dev/null || true
log "Audit rules installed (RKE2, identity, sudo, SSH, cron)"

# =============================================================================
# 8. SNAPSHOT CLEANUP
# =============================================================================
echo "--- [8/8] Snapshot cleanup ---"

apt-get autoremove -y -qq 2>/dev/null
apt-get clean

# Reset machine identity (new ID generated on first boot of cloned node)
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id

# Reset cloud-init (re-runs on cloned node to set hostname, network, etc.)
cloud-init clean --logs 2>/dev/null || true

# Clean temp files and logs
rm -rf /tmp/* /var/tmp/*
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
rm -rf /var/log/*.gz /var/log/*.[0-9] /var/log/*.old

# Clear shell history
history -c 2>/dev/null || true
cat /dev/null > ~/.bash_history 2>/dev/null || true

echo
echo "============================================="
echo "  Base image ready!"
echo "============================================="
echo
echo "  SSH:      key-only, no root, max 3 retries"
echo "  Fail2ban: 3 retries → 1h ban"
echo "  UFW:      eth0=SSH only, ${PRIVATE_IFACE}=all traffic"
echo "  Auditd:   monitoring RKE2, identity, sudo"
echo "  Journald: 1G cap, 7-day retention"
echo "  Swap:     disabled"
echo "  NTP:      synced (UTC)"
echo
echo "  Next: sudo shutdown -h now"
echo "        Then snapshot from Hetzner console."
echo "============================================="
