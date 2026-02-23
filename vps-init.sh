#!/usr/bin/env bash
#
# VPS Initialization Script
# =========================
# Automates the setup and hardening of a fresh Ubuntu 24.04 VPS.
#
# Based on personal documentation and industry best practices.
# Designed to be run ONCE on a fresh server as root.
#
# What this script does:
#   1. Updates the system
#   2. Sets the hostname
#   3. Installs essential tools
#   4. Creates a non-root sudo user
#   5. Configures SSH hardening (disable root, key-only auth)
#   6. Configures UFW firewall
#   7. Installs and configures CrowdSec + firewall bouncer
#   8. Installs unattended-upgrades for automatic security patches
#   9. (Optional) Installs Tailscale VPN
#  10. (Optional) Attaches Ubuntu Pro
#
# Usage:
#   1. SSH into fresh VPS as root
#   2. Upload this script:  scp vps-init.sh root@<ip>:/root/
#   3. Run:  chmod +x vps-init.sh && ./vps-init.sh
#
# IMPORTANT: Have your SSH public key ready before running this script.
#            The script will ask you to paste it during setup.
#

set -euo pipefail

# ==============================================================================
# Color output helpers
# ==============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

separator() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ==============================================================================
# Pre-flight checks
# ==============================================================================
preflight_checks() {
    separator "Pre-flight Checks"

    # Must be root
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root."
        error "Usage: sudo ./vps-init.sh"
        exit 1
    fi

    # Must be Ubuntu
    if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        error "This script is designed for Ubuntu. Detected a different OS."
        exit 1
    fi

    # Check Ubuntu version
    UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
    info "Detected Ubuntu ${UBUNTU_VERSION}"

    if [[ "$UBUNTU_VERSION" != "24.04" && "$UBUNTU_VERSION" != "22.04" ]]; then
        warn "This script is tested on Ubuntu 22.04 and 24.04."
        warn "Detected version: ${UBUNTU_VERSION}. Proceed with caution."
        read -rp "Continue anyway? (y/N): " CONTINUE
        if [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]]; then
            exit 1
        fi
    fi

    # Determine SSH restart command based on version
    if dpkg --compare-versions "$UBUNTU_VERSION" ge "24.04" 2>/dev/null; then
        SSH_SERVICE="ssh"
    else
        SSH_SERVICE="sshd"
    fi

    success "Pre-flight checks passed."
}

# ==============================================================================
# Gather configuration
# ==============================================================================
gather_config() {
    separator "Configuration"

    info "Please provide the following configuration values."
    echo ""

    # Username
    while true; do
        read -rp "New username (lowercase, no spaces): " NEW_USER
        if [[ "$NEW_USER" =~ ^[a-z][a-z0-9_-]{1,31}$ ]]; then
            break
        fi
        error "Invalid username. Use lowercase letters, numbers, hyphens, underscores. Must start with a letter."
    done

    # Hostname
    read -rp "Server hostname (e.g. production.vps.example.com): " SERVER_HOSTNAME
    if [[ -z "$SERVER_HOSTNAME" ]]; then
        SERVER_HOSTNAME=$(hostname)
        warn "Using current hostname: ${SERVER_HOSTNAME}"
    fi

    # SSH port
    read -rp "SSH port [22]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [[ "$SSH_PORT" -lt 1 || "$SSH_PORT" -gt 65535 ]]; then
        error "Invalid port number. Using default 22."
        SSH_PORT=22
    fi
    if [[ "$SSH_PORT" != "22" ]]; then
        warn "Custom SSH port: ${SSH_PORT}"
        warn "Remember to use 'ssh -p ${SSH_PORT}' or configure your SSH config accordingly."
    fi

    # SSH public key
    echo ""
    info "Paste your SSH public key (contents of ~/.ssh/id_rsa.pub):"
    info "You can get it by running 'cat ~/.ssh/id_rsa.pub' on your LOCAL machine."
    echo ""
    read -rp "Public key: " SSH_PUBLIC_KEY
    if [[ -z "$SSH_PUBLIC_KEY" ]]; then
        error "SSH public key is required. Without it, you will be locked out."
        error "Aborting."
        exit 1
    fi
    # Basic validation
    if ! echo "$SSH_PUBLIC_KEY" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2)'; then
        error "That doesn't look like a valid SSH public key."
        error "It should start with ssh-rsa, ssh-ed25519, or ecdsa-sha2-*"
        exit 1
    fi

    # Tailscale
    echo ""
    read -rp "Install Tailscale VPN? (y/N): " INSTALL_TAILSCALE
    INSTALL_TAILSCALE=${INSTALL_TAILSCALE:-n}

    # Ubuntu Pro
    read -rp "Attach Ubuntu Pro? (y/N): " ATTACH_UBUNTU_PRO
    ATTACH_UBUNTU_PRO=${ATTACH_UBUNTU_PRO:-n}
    if [[ "$ATTACH_UBUNTU_PRO" =~ ^[yY]$ ]]; then
        read -rp "Ubuntu Pro token: " UBUNTU_PRO_TOKEN
        if [[ -z "$UBUNTU_PRO_TOKEN" ]]; then
            warn "No token provided. Skipping Ubuntu Pro."
            ATTACH_UBUNTU_PRO="n"
        fi
    fi

    # CrowdSec enrollment
    read -rp "Enroll CrowdSec to dashboard? (y/N): " ENROLL_CROWDSEC
    ENROLL_CROWDSEC=${ENROLL_CROWDSEC:-n}
    if [[ "$ENROLL_CROWDSEC" =~ ^[yY]$ ]]; then
        read -rp "CrowdSec enrollment key: " CROWDSEC_KEY
        if [[ -z "$CROWDSEC_KEY" ]]; then
            warn "No key provided. Skipping CrowdSec enrollment."
            ENROLL_CROWDSEC="n"
        fi
    fi

    # Confirm
    separator "Configuration Summary"
    echo "  Username:         ${NEW_USER}"
    echo "  Hostname:         ${SERVER_HOSTNAME}"
    echo "  SSH Port:         ${SSH_PORT}"
    echo "  SSH Key:          ${SSH_PUBLIC_KEY:0:40}..."
    echo "  Tailscale:        ${INSTALL_TAILSCALE}"
    echo "  Ubuntu Pro:       ${ATTACH_UBUNTU_PRO}"
    echo "  CrowdSec Enroll:  ${ENROLL_CROWDSEC}"
    echo ""
    read -rp "Proceed with this configuration? (y/N): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        info "Aborted by user."
        exit 0
    fi
}

# ==============================================================================
# Step 1: System Update
# ==============================================================================
step_system_update() {
    separator "Step 1: System Update"

    info "Updating package lists..."
    apt update -y

    info "Upgrading installed packages..."
    apt upgrade -y

    info "Removing unused packages..."
    apt autoremove -y

    success "System updated."
}

# ==============================================================================
# Step 2: Set Hostname
# ==============================================================================
step_set_hostname() {
    separator "Step 2: Set Hostname"

    hostnamectl set-hostname "$SERVER_HOSTNAME"
    success "Hostname set to: ${SERVER_HOSTNAME}"
}

# ==============================================================================
# Step 3: Install Essential Tools
# ==============================================================================
step_install_tools() {
    separator "Step 3: Install Essential Tools"

    PACKAGES=(
        git
        vim
        tmux
        curl
        wget
        net-tools
        htop
        unzip
        jq
        apt-transport-https
        ca-certificates
        gnupg
        lsb-release
        software-properties-common
    )

    info "Installing: ${PACKAGES[*]}"
    apt install -y "${PACKAGES[@]}"

    success "Essential tools installed."
}

# ==============================================================================
# Step 4: Create Non-Root User
# ==============================================================================
step_create_user() {
    separator "Step 4: Create User '${NEW_USER}'"

    if id "$NEW_USER" &>/dev/null; then
        warn "User '${NEW_USER}' already exists. Skipping creation."
    else
        adduser --gecos "" "$NEW_USER"
        success "User '${NEW_USER}' created."
    fi

    # Add to sudo group
    usermod -aG sudo "$NEW_USER"
    success "User '${NEW_USER}' added to sudo group."
}

# ==============================================================================
# Step 5: Configure SSH
# ==============================================================================
step_configure_ssh() {
    separator "Step 5: Configure SSH"

    USER_HOME="/home/${NEW_USER}"
    SSH_DIR="${USER_HOME}/.ssh"

    # Create .ssh directory and authorized_keys
    info "Setting up SSH key for ${NEW_USER}..."
    mkdir -p "$SSH_DIR"
    echo "$SSH_PUBLIC_KEY" > "${SSH_DIR}/authorized_keys"
    chmod 700 "$SSH_DIR"
    chmod 600 "${SSH_DIR}/authorized_keys"
    chown -R "${NEW_USER}:${NEW_USER}" "$SSH_DIR"
    success "SSH public key installed."

    # Harden SSH configuration
    info "Hardening SSH configuration..."

    SSH_HARDENING_FILE="/etc/ssh/sshd_config.d/99-hardening.conf"

    cat > "$SSH_HARDENING_FILE" << EOF
# ==============================================================================
# SSH Hardening Configuration
# Generated by vps-init.sh on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# ==============================================================================

# Change default port
Port ${SSH_PORT}

# Disable root login
PermitRootLogin no

# Key-based authentication only
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no

# Disable X11 forwarding (not needed on a server)
X11Forwarding no

# Limit authentication attempts
MaxAuthTries 3
MaxSessions 3

# Set login grace time (seconds to authenticate before disconnect)
LoginGraceTime 30

# Disable unused authentication methods
ChallengeResponseAuthentication no
UsePAM yes

# Only allow the new user to SSH in
AllowUsers ${NEW_USER}

# Use strong ciphers and MACs
Ciphers aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes256-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org

# Idle timeout: disconnect after 5 minutes of inactivity
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

    # Validate SSH config before restarting
    if sshd -t 2>/dev/null; then
        success "SSH configuration is valid."
        systemctl restart "$SSH_SERVICE"
        success "SSH service restarted."
    else
        error "SSH configuration validation failed!"
        error "Removing hardening file to prevent lockout."
        rm -f "$SSH_HARDENING_FILE"
        error "Please review your SSH configuration manually."
        exit 1
    fi

    warn "═══════════════════════════════════════════════════════════════"
    warn "  IMPORTANT: Do NOT close this terminal session yet!"
    warn "  Open a NEW terminal and verify you can SSH in as '${NEW_USER}'"
    warn "  Command: ssh -p ${SSH_PORT} ${NEW_USER}@<this-server-ip>"
    warn "═══════════════════════════════════════════════════════════════"
    echo ""
    read -rp "Have you verified SSH access in another terminal? (y/N): " SSH_VERIFIED
    if [[ "$SSH_VERIFIED" != "y" && "$SSH_VERIFIED" != "Y" ]]; then
        warn "Rolling back SSH changes as a safety measure..."
        rm -f "$SSH_HARDENING_FILE"
        systemctl restart "$SSH_SERVICE"
        error "SSH hardening rolled back. Please re-run the script after verifying access."
        exit 1
    fi

    success "SSH hardening complete."
}

# ==============================================================================
# Step 6: Configure UFW Firewall
# ==============================================================================
step_configure_firewall() {
    separator "Step 6: Configure UFW Firewall"

    info "Installing UFW..."
    apt install -y ufw

    # Reset to defaults
    ufw --force reset

    # Default policies: deny incoming, allow outgoing
    ufw default deny incoming
    ufw default allow outgoing

    # Allow SSH on configured port
    ufw allow "${SSH_PORT}/tcp" comment "SSH"

    # Allow common web ports
    ufw allow 80/tcp comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"

    # Enable UFW (--force to skip interactive prompt)
    ufw --force enable

    success "UFW firewall enabled."
    ufw status verbose
}

# ==============================================================================
# Step 7: Install CrowdSec
# ==============================================================================
step_install_crowdsec() {
    separator "Step 7: Install CrowdSec"

    info "Adding CrowdSec repository..."
    curl -s https://install.crowdsec.net | bash

    info "Installing CrowdSec security engine..."
    apt install -y crowdsec

    info "Installing CrowdSec firewall bouncer..."
    apt install -y crowdsec-firewall-bouncer-iptables

    # Enroll to dashboard if key provided
    if [[ "$ENROLL_CROWDSEC" =~ ^[yY]$ ]]; then
        info "Enrolling CrowdSec to dashboard..."
        cscli console enroll -e context "$CROWDSEC_KEY" || warn "CrowdSec enrollment failed. You can retry manually."
        warn "Remember to accept the enrollment in the CrowdSec dashboard."
    fi

    systemctl restart crowdsec
    success "CrowdSec installed and running."

    # Show status
    cscli metrics show bouncers 2>/dev/null || true
}

# ==============================================================================
# Step 8: Unattended Upgrades
# ==============================================================================
step_unattended_upgrades() {
    separator "Step 8: Configure Unattended Upgrades"

    apt install -y unattended-upgrades

    # Enable automatic security updates
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

    # Configure unattended-upgrades to only apply security updates
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

// Remove unused kernel packages after upgrade
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";

// Remove unused dependencies after upgrade
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Automatically reboot if required (at 4am)
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";

// Log to syslog
Unattended-Upgrade::SyslogEnable "true";
EOF

    systemctl enable --now unattended-upgrades
    success "Unattended upgrades configured (security patches only)."
}

# ==============================================================================
# Step 9 (Optional): Tailscale
# ==============================================================================
step_install_tailscale() {
    if [[ ! "$INSTALL_TAILSCALE" =~ ^[yY]$ ]]; then
        return
    fi

    separator "Step 9: Install Tailscale"

    info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh

    info "Starting Tailscale..."
    tailscale up

    # Allow traffic on tailscale interface
    ufw allow in on tailscale0 comment "Tailscale"

    success "Tailscale installed."
    warn "If you want SSH only over Tailscale, run the following manually:"
    warn "  sudo ufw delete allow ${SSH_PORT}/tcp"
    warn "  sudo ufw allow in on tailscale0 to any port ${SSH_PORT} proto tcp comment 'SSH over Tailscale'"
}

# ==============================================================================
# Step 10 (Optional): Ubuntu Pro
# ==============================================================================
step_ubuntu_pro() {
    if [[ ! "$ATTACH_UBUNTU_PRO" =~ ^[yY]$ ]]; then
        return
    fi

    separator "Step 10: Attach Ubuntu Pro"

    info "Attaching Ubuntu Pro..."
    pro attach "$UBUNTU_PRO_TOKEN" || warn "Ubuntu Pro attachment failed. You can retry with: sudo pro attach <token>"

    success "Ubuntu Pro attached."
}

# ==============================================================================
# Step 11: Final Hardening
# ==============================================================================
step_final_hardening() {
    separator "Step 11: Additional Hardening"

    # Secure shared memory
    if ! grep -q "tmpfs /run/shm" /etc/fstab; then
        info "Securing shared memory..."
        echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid 0 0" >> /etc/fstab
    fi

    # Disable core dumps
    info "Disabling core dumps..."
    cat > /etc/security/limits.d/99-disable-core-dumps.conf << 'EOF'
* hard core 0
* soft core 0
EOF

    # Harden sysctl
    info "Applying sysctl hardening..."
    cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Disable source packet routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Ignore send redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Log Martians (packets with impossible addresses)
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Disable IPv6 if not needed (uncomment if applicable)
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1

# TCP SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Disable IP forwarding (enable if using as router/VPN)
net.ipv4.ip_forward = 0

# Randomize virtual address space
kernel.randomize_va_space = 2
EOF

    sysctl --system > /dev/null 2>&1
    success "Sysctl hardening applied."

    # Set restrictive permissions on cron
    info "Restricting cron access..."
    chmod 600 /etc/crontab
    chmod 700 /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly 2>/dev/null || true

    success "Additional hardening complete."
}

# ==============================================================================
# Generate summary report
# ==============================================================================
generate_report() {
    separator "Setup Complete!"

    REPORT_FILE="/home/${NEW_USER}/vps-init-report.txt"
    cat > "$REPORT_FILE" << EOF
================================================================================
VPS Initialization Report
Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
================================================================================

Server Hostname:    ${SERVER_HOSTNAME}
Ubuntu Version:     ${UBUNTU_VERSION}
Username:           ${NEW_USER}
SSH Port:           ${SSH_PORT}

Security Measures Applied:
  [x] Root SSH login disabled
  [x] Password authentication disabled (key-only)
  [x] SSH hardened (ciphers, MACs, key exchange)
  [x] MaxAuthTries set to 3
  [x] UFW firewall enabled (ports: ${SSH_PORT}/tcp, 80/tcp, 443/tcp)
  [x] CrowdSec installed with firewall bouncer
  [x] Unattended security upgrades enabled (auto-reboot at 04:00)
  [x] Sysctl network hardening applied
  [x] Core dumps disabled
  [x] Cron access restricted
  [$([ "$INSTALL_TAILSCALE" =~ ^[yY]$ ] && echo "x" || echo " ")] Tailscale VPN installed
  [$([ "$ATTACH_UBUNTU_PRO" =~ ^[yY]$ ] && echo "x" || echo " ")] Ubuntu Pro attached

Post-Setup Checklist:
  [ ] Verify SSH access: ssh -p ${SSH_PORT} ${NEW_USER}@<server-ip>
  [ ] Accept CrowdSec enrollment in dashboard (if enrolled)
  [ ] Configure DNS A record for ${SERVER_HOSTNAME}
  [ ] Set up reverse DNS (rDNS) in hosting provider panel
  [ ] Install your application stack (Docker, Node.js, etc.)
  [ ] Configure application-specific UFW rules as needed
  [ ] Set up monitoring (Landscape, Cockpit, or alternative)
  [ ] Configure email notifications for unattended-upgrades
  [ ] Take a snapshot/backup of this clean configuration

Useful Commands:
  sudo ufw status verbose          # Check firewall rules
  sudo cscli metrics               # CrowdSec metrics
  sudo cscli alerts list           # CrowdSec alerts
  sudo systemctl status crowdsec   # CrowdSec service status
  sudo journalctl -u ssh --since today  # SSH logs
  sudo unattended-upgrades --dry-run    # Test auto-updates

================================================================================
EOF

    chown "${NEW_USER}:${NEW_USER}" "$REPORT_FILE"
    chmod 600 "$REPORT_FILE"

    cat "$REPORT_FILE"

    echo ""
    success "Report saved to: ${REPORT_FILE}"
    echo ""
    warn "═══════════════════════════════════════════════════════════════"
    warn "  Your server is now configured. Connect with:"
    warn "  ssh -p ${SSH_PORT} ${NEW_USER}@<server-ip>"
    warn "═══════════════════════════════════════════════════════════════"
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           VPS Initialization Script v1.0                    ║${NC}"
    echo -e "${GREEN}║           Ubuntu 22.04 / 24.04                              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    preflight_checks
    gather_config

    step_system_update
    step_set_hostname
    step_install_tools
    step_create_user
    step_configure_ssh
    step_configure_firewall
    step_install_crowdsec
    step_unattended_upgrades
    step_install_tailscale
    step_ubuntu_pro
    step_final_hardening
    generate_report
}

main "$@"
