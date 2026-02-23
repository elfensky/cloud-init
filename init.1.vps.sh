#!/usr/bin/env bash
# =============================================================================
# init.vps.sh — OS Hardening for Kubernetes Nodes & Standalone VPS
# Replaces: prepare-rke2-node_2.sh + vps-init.sh
#
# Usage: sudo ./init.vps.sh
# Idempotent: safe to re-run.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# =============================================================================
# Preflight
# =============================================================================
require_root
require_ubuntu

banner "OS Hardening — init.vps.sh" "Ubuntu ${UBUNTU_VERSION}"

# =============================================================================
# Interactive Configuration
# =============================================================================

# --- Step 1: Server purpose ---
ask_choice "Server purpose?" 1 \
    "Kubernetes node|Prepares for RKE2 (ip_forward, kernel modules, no swap)" \
    "Standalone VPS|General-purpose server hardening"
PURPOSE=$REPLY  # 1=k8s, 2=standalone

# --- Step 2: Hostname ---
ask_input "Hostname" "$(hostname)"
NEW_HOSTNAME="$REPLY"
if ! validate_hostname "$NEW_HOSTNAME"; then
    err "Invalid hostname: ${NEW_HOSTNAME}"
    exit 1
fi

# --- Step 3: SSH port ---
ask_input "SSH port" "22" '^[0-9]+$'
SSH_PORT="$REPLY"
if ! validate_port "$SSH_PORT"; then
    err "Invalid port: ${SSH_PORT}"
    exit 1
fi

# --- Step 4: Non-root user ---
CREATE_USER="n"
NEW_USER=""
SSH_PUBLIC_KEY=""
if ask_yesno "Create a non-root sudo user?" "y"; then
    CREATE_USER="y"

    ask_input "Username" "" '^[a-z][a-z0-9_-]*$'
    NEW_USER="$REPLY"
    if ! validate_username "$NEW_USER"; then
        err "Invalid username: ${NEW_USER}"
        exit 1
    fi

    echo ""
    info "Paste the SSH public key for ${NEW_USER}:"
    read -rp "Public key: " SSH_PUBLIC_KEY
    if [[ -z "$SSH_PUBLIC_KEY" ]]; then
        err "SSH public key is required."
        exit 1
    fi
    if ! validate_ssh_key "$SSH_PUBLIC_KEY"; then
        err "Invalid SSH key. Must start with ssh-rsa, ssh-ed25519, or ecdsa-sha2."
        exit 1
    fi
fi

# --- Step 5: Private interface (K8s only) ---
PRIVATE_IFACE=""
if [[ "$PURPOSE" -eq 1 ]]; then
    if detect_private_iface; then
        info "Detected private interface: ${PRIVATE_IFACE}"
        if ! ask_yesno "Use ${PRIVATE_IFACE}?" "y"; then
            ask_input "Private interface name" "$PRIVATE_IFACE"
            PRIVATE_IFACE="$REPLY"
        fi
    else
        warn "No private interface auto-detected."
        ask_input "Private interface name" "enp7s0"
        PRIVATE_IFACE="$REPLY"
    fi

    if ! ip link show "${PRIVATE_IFACE}" &>/dev/null; then
        err "Interface '${PRIVATE_IFACE}' not found. Check with 'ip a'."
        exit 1
    fi
fi

# --- Step 6: Security tool ---
ask_choice "Security tool?" 1 \
    "Fail2ban|Lightweight SSH brute-force protection" \
    "CrowdSec|Collaborative security engine with community blocklists"
SECURITY_TOOL=$REPLY  # 1=fail2ban, 2=crowdsec

CROWDSEC_KEY=""
if [[ "$SECURITY_TOOL" -eq 2 ]]; then
    if ask_yesno "Enroll CrowdSec in dashboard?" "n"; then
        ask_input "CrowdSec enrollment key" ""
        CROWDSEC_KEY="$REPLY"
    fi
fi

# --- Step 7: Tailscale ---
INSTALL_TAILSCALE="n"
if ask_yesno "Install Tailscale VPN?" "n"; then
    INSTALL_TAILSCALE="y"
fi

# --- Step 8: Unattended upgrades ---
INSTALL_UNATTENDED="y"
if ! ask_yesno "Enable unattended security upgrades?" "y"; then
    INSTALL_UNATTENDED="n"
fi

# --- Step 9: Ubuntu Pro ---
ATTACH_PRO="n"
PRO_TOKEN=""
if ask_yesno "Attach Ubuntu Pro?" "n"; then
    ask_input "Ubuntu Pro token" ""
    PRO_TOKEN="$REPLY"
    ATTACH_PRO="y"
fi

# --- Step 10: Confirmation ---
PURPOSE_LABEL="Kubernetes node"
[[ "$PURPOSE" -eq 2 ]] && PURPOSE_LABEL="Standalone VPS"

SECURITY_LABEL="Fail2ban"
[[ "$SECURITY_TOOL" -eq 2 ]] && SECURITY_LABEL="CrowdSec"

summary_args=(
    "Purpose|${PURPOSE_LABEL}"
    "Hostname|${NEW_HOSTNAME}"
    "SSH Port|${SSH_PORT}"
)
[[ "$CREATE_USER" == "y" ]] && summary_args+=("User|${NEW_USER}")
[[ "$CREATE_USER" == "y" ]] && summary_args+=("SSH Key|${SSH_PUBLIC_KEY:0:40}...")
[[ "$PURPOSE" -eq 1 ]] && summary_args+=("Private Iface|${PRIVATE_IFACE}")
summary_args+=(
    "Security|${SECURITY_LABEL}"
    "Tailscale|${INSTALL_TAILSCALE}"
    "Unattended|${INSTALL_UNATTENDED}"
    "Ubuntu Pro|${ATTACH_PRO}"
)

print_summary "Configuration Summary" "${summary_args[@]}"

if ! ask_yesno "Proceed with this configuration?" "n"; then
    info "Aborted by user."
    exit 0
fi

# =============================================================================
# Execution
# =============================================================================

# --- 1. System update ---
separator "System Update"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
log "System updated"

# --- 2. Set hostname ---
separator "Hostname"
hostnamectl set-hostname "$NEW_HOSTNAME"
log "Hostname set to: ${NEW_HOSTNAME}"

# --- 3. Install packages ---
separator "Packages"

COMMON_PACKAGES=(
    curl wget ca-certificates gnupg lsb-release
    apt-transport-https software-properties-common
    jq git vim tmux htop unzip net-tools
)

K8S_PACKAGES=(
    ipset conntrack socat
    open-iscsi nfs-common
    auditd audispd-plugins
)

if [[ "$PURPOSE" -eq 1 ]]; then
    apt-get install -y -qq "${COMMON_PACKAGES[@]}" "${K8S_PACKAGES[@]}" 2>/dev/null
    systemctl enable iscsid --now 2>/dev/null
    log "Common + Kubernetes packages installed"
else
    apt-get install -y -qq "${COMMON_PACKAGES[@]}" 2>/dev/null
    log "Common packages installed"
fi

# --- 4. Create user ---
if [[ "$CREATE_USER" == "y" ]]; then
    separator "User: ${NEW_USER}"

    if id "$NEW_USER" &>/dev/null; then
        warn "User '${NEW_USER}' already exists. Skipping creation."
    else
        adduser --disabled-password --gecos "" "$NEW_USER"
        log "User '${NEW_USER}' created."
    fi

    usermod -aG sudo "$NEW_USER"

    USER_HOME="/home/${NEW_USER}"
    SSH_DIR="${USER_HOME}/.ssh"
    mkdir -p "$SSH_DIR"
    echo "$SSH_PUBLIC_KEY" > "${SSH_DIR}/authorized_keys"
    chmod 700 "$SSH_DIR"
    chmod 600 "${SSH_DIR}/authorized_keys"
    chown -R "${NEW_USER}:${NEW_USER}" "$SSH_DIR"
    log "SSH key installed for ${NEW_USER}"
fi

# --- 5. SSH hardening ---
separator "SSH Hardening"

detect_ssh_service || { err "Could not find SSH service"; exit 1; }

SSH_HARDENING_FILE="/etc/ssh/sshd_config.d/99-hardening.conf"

# Build AllowUsers line
ALLOW_USERS=""
if [[ "$CREATE_USER" == "y" ]]; then
    ALLOW_USERS="AllowUsers ${NEW_USER}"
fi

cat > "$SSH_HARDENING_FILE" << EOF
# Generated by init.vps.sh on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Port ${SSH_PORT}
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
X11Forwarding no
MaxAuthTries 3
MaxSessions 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowTcpForwarding no
AllowAgentForwarding no
${ALLOW_USERS}
Ciphers aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes256-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
EOF

if sshd -t 2>/dev/null; then
    systemctl reload "$SSH_SERVICE"
    log "SSH hardened (key-only, no root, port ${SSH_PORT}) [service: ${SSH_SERVICE}]"
else
    err "SSH config validation failed! Removing hardening file."
    rm -f "$SSH_HARDENING_FILE"
    exit 1
fi

if [[ "$CREATE_USER" == "y" ]]; then
    echo ""
    warn "═══════════════════════════════════════════════════════════════"
    warn "  IMPORTANT: Do NOT close this terminal session!"
    warn "  Open a NEW terminal and verify SSH access:"
    warn "  ssh -p ${SSH_PORT} ${NEW_USER}@<this-server-ip>"
    warn "═══════════════════════════════════════════════════════════════"
    echo ""
    if ! ask_yesno "Have you verified SSH access in another terminal?" "n"; then
        warn "Rolling back SSH hardening..."
        rm -f "$SSH_HARDENING_FILE"
        systemctl reload "$SSH_SERVICE"
        err "SSH hardening rolled back. Re-run the script after verifying access."
        exit 1
    fi
fi

# --- 6. UFW firewall ---
separator "UFW Firewall"

apt-get install -y -qq ufw 2>/dev/null
ufw --force reset >/dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing

if [[ "$PURPOSE" -eq 1 ]]; then
    # K8s: SSH on public interface only, allow all on private
    ufw allow in on eth0 to any port "${SSH_PORT}" proto tcp comment 'SSH'
    ufw allow in on "${PRIVATE_IFACE}" comment 'Private network'
    log "UFW: eth0=SSH only, ${PRIVATE_IFACE}=all traffic"
else
    # Standalone: SSH + HTTP + HTTPS
    ufw allow "${SSH_PORT}/tcp" comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    log "UFW: SSH(${SSH_PORT}) + HTTP + HTTPS"
fi

ufw --force enable

# --- 7. Security tool ---
separator "Security: ${SECURITY_LABEL}"

if [[ "$SECURITY_TOOL" -eq 1 ]]; then
    # Fail2ban
    apt-get install -y -qq fail2ban 2>/dev/null

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
else
    # CrowdSec
    curl -s https://install.crowdsec.net | bash
    apt-get install -y crowdsec crowdsec-firewall-bouncer-iptables

    if [[ -n "$CROWDSEC_KEY" ]]; then
        cscli console enroll -e context "$CROWDSEC_KEY" || warn "CrowdSec enrollment failed."
        warn "Accept the enrollment in the CrowdSec dashboard."
    fi

    systemctl restart crowdsec
    log "CrowdSec installed and running"
fi

# --- 8. Kernel modules + sysctl ---
separator "Kernel & Sysctl"

if [[ "$PURPOSE" -eq 1 ]]; then
    # K8s kernel modules
    cat > /etc/modules-load.d/rke2.conf <<'MODEOF'
overlay
br_netfilter
nf_conntrack
xt_set
ip_set
ip_set_hash_ip
ip_set_hash_net
MODEOF

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
SYSEOF

    log "K8s kernel modules loaded, sysctl configured (ip_forward=1)"
else
    # Standalone sysctl
    cat > /etc/sysctl.d/99-hardening.conf <<'SYSEOF'
# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcast
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Disable redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
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

# Disable IP forwarding (not a router)
net.ipv4.ip_forward = 0

# ASLR
kernel.randomize_va_space = 2
SYSEOF

    log "Standalone sysctl hardening applied (ip_forward=0)"
fi

sysctl --system >/dev/null 2>&1

# --- 9. System configuration ---
separator "System Configuration"

if [[ "$PURPOSE" -eq 1 ]]; then
    # Disable swap
    swapoff -a
    sed -i '/\sswap\s/s/^/#/' /etc/fstab
    log "Swap disabled"

    # Raise file descriptor limits
    cat > /etc/security/limits.d/99-rke2.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    log "File descriptor limits raised"
else
    # Disable core dumps
    cat > /etc/security/limits.d/99-disable-core-dumps.conf <<'EOF'
* hard core 0
* soft core 0
EOF
    log "Core dumps disabled"

    # Secure shared memory
    if ! grep -q "tmpfs /run/shm" /etc/fstab; then
        echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid 0 0" >> /etc/fstab
    fi

    # Restrict cron
    chmod 600 /etc/crontab
    chmod 700 /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly 2>/dev/null || true
    log "Standalone hardening applied"
fi

# Journald cap (both modes)
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-cap.conf <<'EOF'
[Journal]
SystemMaxUse=1G
SystemMaxFileSize=100M
MaxRetentionSec=7day
Compress=yes
EOF
systemctl restart systemd-journald
log "Journald: 1G cap, 7-day retention"

# Timezone + NTP (both modes)
timedatectl set-timezone UTC
systemctl enable systemd-timesyncd --now 2>/dev/null
log "Timezone UTC, NTP enabled"

# --- 10. Audit rules (K8s only) ---
if [[ "$PURPOSE" -eq 1 ]]; then
    separator "Audit Rules"

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
    log "Audit rules installed (RKE2, identity, sudo, cron)"
fi

# --- 11. Unattended upgrades ---
if [[ "$INSTALL_UNATTENDED" == "y" ]]; then
    separator "Unattended Upgrades"

    apt-get install -y -qq unattended-upgrades 2>/dev/null

    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::SyslogEnable "true";
EOF

    systemctl enable --now unattended-upgrades
    log "Unattended upgrades configured (security patches, reboot at 04:00)"
fi

# --- 12. Tailscale ---
if [[ "$INSTALL_TAILSCALE" == "y" ]]; then
    separator "Tailscale"
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up
    ufw allow in on tailscale0 comment 'Tailscale'
    log "Tailscale installed"
fi

# --- 13. Ubuntu Pro ---
if [[ "$ATTACH_PRO" == "y" ]]; then
    separator "Ubuntu Pro"
    pro attach "$PRO_TOKEN" || warn "Ubuntu Pro attachment failed."
    log "Ubuntu Pro attached"
fi

# --- 14. Summary report ---
separator "Complete"

REPORT_DIR="/root"
[[ "$CREATE_USER" == "y" ]] && REPORT_DIR="/home/${NEW_USER}"
REPORT_FILE="${REPORT_DIR}/init-report.txt"

{
    echo "================================================================================"
    echo "OS Hardening Report"
    echo "Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "================================================================================"
    echo ""
    echo "  Purpose:        ${PURPOSE_LABEL}"
    echo "  Hostname:        ${NEW_HOSTNAME}"
    echo "  Ubuntu:          ${UBUNTU_VERSION}"
    echo "  SSH Port:        ${SSH_PORT}"
    [[ "$CREATE_USER" == "y" ]] && echo "  User:            ${NEW_USER}"
    [[ "$PURPOSE" -eq 1 ]] && echo "  Private Iface:   ${PRIVATE_IFACE}"
    echo "  Security:        ${SECURITY_LABEL}"
    echo "  Tailscale:       ${INSTALL_TAILSCALE}"
    echo "  Unattended:      ${INSTALL_UNATTENDED}"
    echo "  Ubuntu Pro:      ${ATTACH_PRO}"
    echo ""
    if [[ "$PURPOSE" -eq 1 ]]; then
        echo "  Kernel:          overlay, br_netfilter, ip_forward=1"
        echo "  Swap:            disabled"
        echo "  Auditd:          RKE2 rules active"
    else
        echo "  Kernel:          ip_forward=0, rp_filter=1, martians"
        echo "  Core dumps:      disabled"
    fi
    echo ""
    echo "Next steps:"
    if [[ "$PURPOSE" -eq 1 ]]; then
        echo "  Run init.rke2.sh to install RKE2 on this node."
    else
        echo "  Your server is ready for application deployment."
    fi
    [[ "$CREATE_USER" == "y" ]] && echo "  SSH: ssh -p ${SSH_PORT} ${NEW_USER}@<server-ip>"
    echo "================================================================================"
} > "$REPORT_FILE"

if [[ "$CREATE_USER" == "y" ]]; then
    chown "${NEW_USER}:${NEW_USER}" "$REPORT_FILE"
fi
chmod 600 "$REPORT_FILE"

cat "$REPORT_FILE"

echo ""
log "Report saved to: ${REPORT_FILE}"

apt-get autoremove -y -qq 2>/dev/null
apt-get clean
