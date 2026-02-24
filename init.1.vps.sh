#!/usr/bin/env bash
# =============================================================================
# init.1.vps.sh — OS Hardening for Kubernetes Nodes & Standalone VPS
# =============================================================================
#
# Purpose
# -------
# Hardens a fresh Ubuntu 24.04 server for production use. Supports two modes:
#   1) Kubernetes node — prepares the host for RKE2 installation
#   2) Standalone VPS  — general-purpose server hardening
#
# Usage
# -----
#   sudo ./init.1.vps.sh
#
# Idempotency
# -----------
# Safe to re-run. All configs are overwritten via `cat >`, never appended.
# Running the script again produces the same end state regardless of how many
# times it has been executed previously.
#
# Interactive Steps
# -----------------
#   1.  Server purpose    — Kubernetes node or standalone VPS
#   2.  Hostname          — sets system hostname via hostnamectl
#   3.  SSH port          — non-standard port to reduce bot noise in logs
#   4.  Non-root user     — creates sudo user with SSH public key
#   5.  Private interface — (K8s only) for cluster-internal traffic
#   6.  Security tool     — Fail2ban or CrowdSec
#   7.  Tailscale         — optional mesh VPN overlay
#   8.  Unattended upgrades — automatic security patches
#   9.  Ubuntu Pro        — optional ESM/Livepatch enrollment
#   10. Confirmation      — review summary, then execute or abort
#
# What Changes Between Modes
# --------------------------
#                        Kubernetes node           Standalone VPS
#   Packages:            + ipset conntrack socat    common only
#                          open-iscsi nfs-common
#                          auditd audispd-plugins
#   Kernel params:       ip_forward=1, overlay,    ip_forward=0, rp_filter,
#                        br_netfilter, nf_conntrack ASLR, log_martians
#   Swap:                disabled (kubelet req)    left as-is
#   UFW rules:           SSH on public iface,      SSH + HTTP + HTTPS
#                        all traffic on private
#   Audit rules:         RKE2 binary/config,       none
#                        identity, sudo, cron
#   File limits:         nofile 1048576            default
#   Core dumps:          default                   disabled
#
# Both Modes
# ----------
#   - SSH hardening: key-only auth, no root login, rate-limited
#     Writes /etc/ssh/sshd_config.d/99-hardening.conf, validates with sshd -t,
#     rolls back the drop-in file on validation failure. Pauses after reload
#     so the operator can verify SSH access from a second terminal before
#     proceeding (prevents lockout).
#   - Journald: 1G cap, 100MB per file, 7-day retention, compressed
#   - Timezone: UTC
#   - NTP: systemd-timesyncd enabled
#
# Output
# ------
#   ~/init-report.txt — summary of applied configuration (chmod 600)
#
# Next Steps
# ----------
#   Kubernetes  -> run init.2.rke2.sh to install RKE2
#   Standalone  -> server is ready for application deployment
# =============================================================================

# Exit immediately on command failure (-e), treat unset variables as errors
# (-u), and fail pipelines on the first non-zero exit code instead of only
# checking the last command (-o pipefail). Together these prevent silent
# failures from propagating through the script.
set -euo pipefail

# Resolve the directory containing this script using BASH_SOURCE[0] instead
# of $0. BASH_SOURCE is reliable even when the script is sourced or invoked
# through a symlink, whereas $0 may resolve to the calling shell.
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
# The choice here determines which code paths execute later: kernel modules,
# sysctl tunables, swap policy, firewall rules, audit rules, and file limits
# all diverge based on whether this host will join a Kubernetes cluster or
# run as a standalone server.
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
# Using a non-standard port is not real security (port scanners find it), but
# it dramatically reduces log noise from automated bots that target port 22,
# making legitimate failed-auth events easier to spot.
ask_input "SSH port" "22" '^[0-9]+$'
SSH_PORT="$REPLY"
if ! validate_port "$SSH_PORT"; then
    err "Invalid port: ${SSH_PORT}"
    exit 1
fi

# --- Step 4: Non-root user ---
# Creates a dedicated sudo user so that root login can be disabled. All
# subsequent operations are performed through this user via sudo, providing
# an audit trail of who ran what.
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

    # An SSH public key is mandatory when creating a user because password
    # authentication will be disabled by the SSH hardening step. Without a
    # valid key the new user would have no way to log in.
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

# Safety: warn if no SSH user will exist after PermitRootLogin=no
if [[ "$CREATE_USER" != "y" ]]; then
    HAS_SSH_USER="n"
    for hdir in /home/*/; do
        [ -d "$hdir" ] || continue
        local_user=$(basename "$hdir")
        if [[ -f "${hdir}.ssh/authorized_keys" ]] && id "$local_user" &>/dev/null; then
            HAS_SSH_USER="y"
            break
        fi
    done

    if [[ "$HAS_SSH_USER" != "y" ]]; then
        echo ""
        warn "═══════════════════════════════════════════════════════════════"
        warn "  No non-root user with SSH keys found on this system!"
        warn "  PermitRootLogin=no will LOCK YOU OUT."
        warn "═══════════════════════════════════════════════════════════════"
        echo ""
        if ! ask_yesno "Continue WITHOUT a non-root SSH user? (DANGEROUS)" "n"; then
            info "Aborted. Re-run and create a user."
            exit 0
        fi
    fi
fi

# --- Step 5: Private interface (K8s only) ---
# Kubernetes nodes communicate over a private (VLAN/VPC) interface for etcd
# replication, kubelet API, and CNI pod-to-pod traffic. Auto-detection tries
# common interface names across major providers (Hetzner enp7s0, DigitalOcean
# eth1, etc.) and falls back to manual entry.
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

# K8s-specific packages:
#   ipset/conntrack — required by kube-proxy for IPVS mode and connection tracking
#   socat           — used by kubectl port-forward to relay TCP connections
#   open-iscsi      — iSCSI initiator for persistent volumes (Longhorn, etc.)
#   nfs-common      — NFS client for NFS-backed persistent volumes
#   auditd          — kernel audit framework for compliance and intrusion detection
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

    # Install the SSH public key with strict permissions. authorized_keys must
    # be 600 and .ssh must be 700 — sshd refuses keys with looser permissions.
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
# This is the most security-critical section of the script. A misconfigured
# SSH daemon can lock out the operator permanently. The approach here is:
#   1. Write a drop-in config to sshd_config.d/ (not the main sshd_config)
#   2. Validate the full config with sshd -t before reloading
#   3. Pause so the operator can verify access from a second terminal
#   4. Roll back if validation fails or the operator reports a problem
#
# Using a drop-in file in sshd_config.d/ instead of editing the main
# sshd_config avoids merge conflicts with OS upgrades and makes changes
# easy to identify, version-control, and remove.
separator "SSH Hardening"

detect_ssh_service || { err "Could not find SSH service"; exit 1; }

SSH_HARDENING_FILE="/etc/ssh/sshd_config.d/99-hardening.conf"

# Build AllowUsers line
ALLOW_USERS=""
if [[ "$CREATE_USER" == "y" ]]; then
    ALLOW_USERS="AllowUsers ${NEW_USER}"
fi

# SSH hardening rationale for each directive:
#
#   Port ${SSH_PORT}            — move off default 22 to reduce automated scan noise
#   PermitRootLogin no          — forces operators to use sudo, creating an audit trail
#                                 of privileged actions tied to individual accounts
#   PubkeyAuthentication yes    — enable key-based auth (the only allowed method)
#   PasswordAuthentication no   — SSH keys provide ~2048+ bit entropy vs ~40 bits for
#                                 a typical password; eliminates brute-force entirely
#   PermitEmptyPasswords no     — defense-in-depth: blocks empty passwords even though
#                                 password auth is disabled above
#   KbdInteractiveAuthentication no — disables challenge-response (PAM keyboard prompts)
#   X11Forwarding no            — X11 forwarding exposes the X server to remote exploits
#   MaxAuthTries 3              — low enough to impede brute-force attacks, high enough
#                                 to tolerate an occasional key-selection typo
#   MaxSessions 3               — limits the number of multiplexed sessions per connection
#                                 to restrict lateral movement through a compromised host
#   LoginGraceTime 30           — 30 seconds to authenticate; short window reduces resource
#                                 consumption from hanging unauthenticated connections
#   ClientAliveInterval 300     — server pings the client every 5 minutes
#   ClientAliveCountMax 2       — after 2 missed pings (10 min idle), disconnect;
#                                 prevents orphaned sessions from lingering
#   AllowTcpForwarding no       — prevents SSH from being used as a tunnel/pivot point
#                                 for lateral movement within the network
#   AllowAgentForwarding no     — prevents a compromised server from hijacking the
#                                 operator's SSH agent to reach other hosts
#   AllowUsers (if set)         — explicit allowlist; only the created user can log in
#
#   Ciphers                     — AEAD ciphers only: AES-256-GCM and ChaCha20-Poly1305
#                                 provide authenticated encryption. AES-256-CTR is
#                                 included as a compatibility fallback (paired with MAC).
#   MACs                        — Encrypt-then-MAC (ETM) variants only; ETM prevents
#                                 padding oracle attacks that affect MAC-then-encrypt
#   KexAlgorithms               — Curve25519 only; avoids NIST P-256/P-384 curves which
#                                 have concerns about potential NSA backdoors in the
#                                 curve generation process
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
HostbasedAuthentication no
${ALLOW_USERS}
Ciphers aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes256-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
EOF

# Validate the full SSH configuration before reloading. If sshd -t fails the
# daemon would refuse to restart, locking out the operator. On failure, remove
# the drop-in file so the previous (working) config remains in effect.
if sshd_output=$(sshd -t 2>&1); then
    systemctl reload "$SSH_SERVICE"
    log "SSH hardened (key-only, no root, port ${SSH_PORT}) [service: ${SSH_SERVICE}]"
else
    err "SSH config validation failed:"
    err "$sshd_output"
    rm -f "$SSH_HARDENING_FILE"
    exit 1
fi

# Safety net: pause the script so the operator can open a second terminal and
# confirm they can still SSH in. If access is broken, rolling back the drop-in
# file and reloading sshd restores the previous configuration immediately.
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
# Reset to a clean slate on every run (idempotent). Default policy: deny all
# incoming, allow all outgoing. Rules are then added based on server purpose.
separator "UFW Firewall"

apt-get install -y -qq ufw 2>/dev/null
ufw --force reset >/dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing

if [[ "$PURPOSE" -eq 1 ]]; then
    # K8s: only SSH is exposed on the public interface. All traffic is allowed
    # on the private interface because cluster components (etcd 2379-2380,
    # kubelet 10250, CNI overlay, NodePort range) need unrestricted comms.
    # Restricting individual ports on the private interface is fragile and
    # breaks as the CNI and service mesh evolve.
    detect_public_iface || { err "Cannot detect public interface for UFW rules"; exit 1; }
    ufw allow in on "${PUBLIC_IFACE}" to any port "${SSH_PORT}" proto tcp comment 'SSH'
    ufw allow in on "${PRIVATE_IFACE}" comment 'Private network'
    log "UFW: ${PUBLIC_IFACE}=SSH only, ${PRIVATE_IFACE}=all traffic"
else
    # Standalone: expose only SSH for management, plus HTTP/HTTPS for web
    # applications. Additional ports can be opened manually after deployment.
    ufw allow "${SSH_PORT}/tcp" comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    log "UFW: SSH(${SSH_PORT}) + HTTP + HTTPS"
fi

ufw --force enable

# --- 7. Security tool ---
separator "Security: ${SECURITY_LABEL}"

if [[ "$SECURITY_TOOL" -eq 1 ]]; then
    # Fail2ban — lightweight, local-only brute-force protection.
    #   bantime  = 3600  — 1-hour ban per offending IP
    #   findtime = 600   — 10-minute sliding window for counting failures
    #   maxretry = 3     — 3 failed attempts within findtime triggers a ban
    #   banaction = ufw  — integrates bans directly with the UFW firewall
    #                      rather than managing iptables rules separately
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
    # CrowdSec — community-driven threat intelligence engine. Analyzes logs
    # locally and shares attack signals with the CrowdSec network. The
    # firewall bouncer automatically blocks IPs from community-curated
    # blocklists in addition to locally detected threats.
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
    # Load kernel modules required by the container runtime and CNI:
    #   overlay        — overlay filesystem driver for container image layers
    #   br_netfilter   — enables iptables to see bridged traffic (required by
    #                    CNI plugins that route pod traffic through Linux bridges)
    #   nf_conntrack   — connection tracking for kube-proxy IPVS/iptables rules
    #   xt_set/ip_set* — ipset support for efficient large-scale network policy
    #                    enforcement (Calico, Cilium iptables mode)
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

    # Sysctl tunables for Kubernetes networking and security:
    #
    #   bridge-nf-call-iptables/ip6tables = 1
    #     Required for CNI plugins (Calico, Flannel, Canal) to intercept
    #     bridged traffic through iptables. Without this, pod-to-pod and
    #     pod-to-service traffic bypasses netfilter rules.
    #
    #   ip_forward = 1, forwarding = 1
    #     Pods on different nodes route traffic through the host. Disabling
    #     forwarding would break all cross-node pod communication.
    #
    #   inotify max_user_watches = 524288, max_user_instances = 8192
    #     Pods create many file watches (ConfigMap/Secret mounts, log
    #     watchers, file-based health checks). Default limits (8192/128)
    #     cause "too many open files" errors in large deployments.
    #
    #   accept_redirects = 0, send_redirects = 0
    #     ICMP redirects can be used for MITM attacks by tricking the host
    #     into rerouting traffic through an attacker-controlled gateway.
    #
    #   tcp_syncookies = 1
    #     Protects against SYN flood attacks without dropping legitimate
    #     connections. The kernel responds with a cryptographic cookie
    #     instead of allocating state for half-open connections.
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

    log "K8s kernel modules loaded, sysctl configured (ip_forward=1)"
else
    # Standalone sysctl hardening — defense-in-depth network and kernel tunables
    # for a server that is NOT a router and does NOT forward packets.
    #
    #   rp_filter = 1
    #     Reverse-path filtering: the kernel drops packets whose source
    #     address would not be routed back through the same interface they
    #     arrived on. Prevents IP spoofing attacks.
    #
    #   icmp_echo_ignore_broadcasts = 1
    #     Ignoring broadcast ICMP echo requests prevents the server from
    #     being used as an amplifier in smurf attacks.
    #
    #   accept_source_route = 0
    #     Source-routed packets let the sender specify the route through the
    #     network, allowing attackers to bypass firewalls and routing rules.
    #
    #   send_redirects = 0
    #     This server is not a router and should never tell other hosts to
    #     reroute traffic. Sending redirects could be exploited for MITM.
    #
    #   log_martians = 1
    #     Logs packets with impossible source addresses (RFC 1918 on public
    #     interfaces, 0.0.0.0, etc.). Useful for detecting spoofing attempts
    #     and misconfigured networks.
    #
    #   tcp_syncookies = 1, max_syn_backlog = 2048
    #     SYN flood protection: syncookies avoid allocating state for
    #     half-open connections, while a larger backlog accommodates
    #     legitimate burst traffic without dropping connections.
    #   tcp_synack_retries = 2, tcp_syn_retries = 5
    #     Reduces the time half-open connections consume resources.
    #
    #   ip_forward = 0
    #     Standalone server is not a router; forwarding is explicitly
    #     disabled to prevent the host from relaying traffic between
    #     interfaces if an attacker adds routes.
    #
    #   randomize_va_space = 2
    #     Full ASLR (Address Space Layout Randomization) for all memory
    #     regions: stack, heap, mmap, VDSO, and PIE executables. Makes
    #     memory-corruption exploits significantly harder.
    cat > /etc/sysctl.d/99-hardening.conf <<'SYSEOF'
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
    # Disable swap — kubelet requires swap to be off for accurate memory
    # resource accounting, pod QoS enforcement, and predictable OOM handling.
    # With swap enabled, the kernel may page out container memory instead of
    # triggering OOM kills, causing unpredictable latency and breaking
    # resource limits.
    swapoff -a
    sed -i '/\sswap\s/s/^/#/' /etc/fstab
    log "Swap disabled"

    # Raise the file descriptor limit to 1M. Kubernetes pods open many
    # connections (service mesh sidecars, database connection pools, log
    # collectors). The default 1024 is far too low and causes "too many
    # open files" errors under production workloads.
    cat > /etc/security/limits.d/99-rke2.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    log "File descriptor limits raised"
else
    # Disable core dumps — core files can contain sensitive data such as
    # encryption keys, database credentials, and user data from application
    # memory. On a production server, core dumps leaking to disk is a
    # security risk with little debugging value.
    cat > /etc/security/limits.d/99-disable-core-dumps.conf <<'EOF'
* hard core 0
* soft core 0
EOF
    log "Core dumps disabled"

    # Restrict cron to root only. chmod 600 on crontab prevents other users
    # from reading scheduled tasks (which may reveal system internals).
    # chmod 700 on cron directories prevents non-root users from dropping
    # scripts into periodic execution directories.
    chmod 600 /etc/crontab
    chmod 700 /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly 2>/dev/null || true
    log "Standalone hardening applied"
fi

# Journald log retention cap (both modes). Without limits, journald can fill
# the disk on a busy server. Settings:
#   SystemMaxUse=1G       — total disk budget for journal files
#   SystemMaxFileSize=100M — individual journal file size before rotation
#   MaxRetentionSec=7day  — oldest entries pruned after 7 days
#   Compress=yes          — journal files are compressed on disk
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

# Set timezone to UTC (both modes). UTC avoids DST confusion in logs, cron
# schedules, and certificate validity checks. NTP ensures clock drift does
# not cause TLS handshake failures or log ordering issues.
timedatectl set-timezone UTC
systemctl enable systemd-timesyncd --now 2>/dev/null
log "Timezone UTC, NTP enabled"

# --- 10. Audit rules (K8s only) ---
# Linux audit framework (auditd) watches for file access and modifications on
# security-sensitive paths. Each rule uses -p flags: w=write, a=attribute
# change, x=execute. The -k flag sets a filter key for easy log searching
# with ausearch -k <key>.
if [[ "$PURPOSE" -eq 1 ]]; then
    separator "Audit Rules"

    cat > /etc/audit/rules.d/rke2.rules <<'EOF'
# RKE2 binaries — detect unauthorized execution or replacement of the
# RKE2 binary and its managed components (kubectl, containerd, etc.)
-w /usr/local/bin/rke2 -p x -k rke2
-w /var/lib/rancher/rke2/bin/ -p x -k rke2-bins

# RKE2/Rancher config and data — detect modifications to cluster
# configuration, manifests, and data directories
-w /etc/rancher/ -p wa -k rancher-config
-w /var/lib/rancher/ -p wa -k rancher-data

# Identity files (passwd, group, shadow) — detect user account creation,
# deletion, or modification that could indicate unauthorized access
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity

# Sudoers — detect privilege escalation attempts via sudo configuration
# changes (adding users, modifying rules, dropping files in sudoers.d/)
-w /etc/sudoers -p wa -k sudo-changes
-w /etc/sudoers.d/ -p wa -k sudo-changes

# Home directories — detect SSH authorized_keys modifications that could
# grant unauthorized access to user accounts
-w /home/ -p wa -k home-changes

# Cron — detect scheduled task tampering that could be used for
# persistence (attacker adds a cron job to maintain access)
-w /etc/crontab -p wa -k cron
-w /etc/cron.d/ -p wa -k cron
EOF

    systemctl enable auditd --now 2>/dev/null
    augenrules --load 2>/dev/null || systemctl restart auditd 2>/dev/null || true
    log "Audit rules installed (RKE2, identity, sudo, cron)"
fi

# --- 11. Unattended upgrades ---
# Automatic security patching ensures the server stays protected against
# known vulnerabilities without manual intervention.
if [[ "$INSTALL_UNATTENDED" == "y" ]]; then
    separator "Unattended Upgrades"

    apt-get install -y -qq unattended-upgrades 2>/dev/null

    # APT periodic settings:
    #   Update-Package-Lists "1"   — refresh package index daily
    #   Unattended-Upgrade "1"     — install upgrades daily
    #   Download-Upgradeable "1"   — pre-download packages daily
    #   AutocleanInterval "7"      — purge old .deb files weekly to free disk
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

    # Allowed origins restrict automatic upgrades to security repositories
    # only. This prevents feature-release upgrades from breaking production
    # workloads while still patching CVEs promptly.
    #   ${distro_id}:${distro_codename}                — base Ubuntu security
    #   ${distro_id}:${distro_codename}-security       — Ubuntu security pocket
    #   ${distro_id}ESMApps:...-apps-security           — ESM application security
    #   ${distro_id}ESM:...-infra-security              — ESM infrastructure security
    #
    # K8s nodes: disable auto-reboot — an uncoordinated reboot can break etcd
    # quorum or drain workloads ungracefully. Use kured for coordinated reboots.
    # Standalone: reboot at 04:00 — low-traffic window for kernel updates that
    # require a restart. Without automatic reboot, the server may run a
    # vulnerable kernel indefinitely after a security patch is installed.
    if [[ "$PURPOSE" -eq 1 ]]; then
        cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
// Auto-reboot disabled for K8s nodes — use kured for coordinated node reboots
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::SyslogEnable "true";
EOF
        systemctl enable --now unattended-upgrades
        log "Unattended upgrades configured (security patches, auto-reboot disabled — use kured)"
    else
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
fi

# --- 12. Tailscale ---
# Tailscale creates a mesh VPN overlay (tailscale0 interface) for secure
# management access across nodes without exposing SSH to the public internet.
# `tailscale up` starts an interactive login flow via URL.
if [[ "$INSTALL_TAILSCALE" == "y" ]]; then
    separator "Tailscale"
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up
    # Allow all traffic on the Tailscale interface — the VPN itself handles
    # authentication and encryption; UFW only needs to permit its traffic.
    ufw allow in on tailscale0 comment 'Tailscale'
    log "Tailscale installed"
fi

# --- 13. Ubuntu Pro ---
# Ubuntu Pro provides Extended Security Maintenance (ESM) for universe packages
# and optional Livepatch for kernel updates without rebooting. The token is
# obtained from https://ubuntu.com/pro/dashboard.
if [[ "$ATTACH_PRO" == "y" ]]; then
    separator "Ubuntu Pro"
    pro attach "$PRO_TOKEN" || warn "Ubuntu Pro attachment failed."
    log "Ubuntu Pro attached"
fi

# --- 14. Summary report ---
# Generate a plain-text report of everything that was configured. The file is
# saved to the created user's home directory (or /root if no user was created)
# with 600 permissions because it contains configuration details (SSH port,
# username, interface names) that could aid reconnaissance.
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

# Set report ownership to the created user (if any) so they can read it
# without sudo. Permissions 600 prevent other users from reading it.
if [[ "$CREATE_USER" == "y" ]]; then
    chown "${NEW_USER}:${NEW_USER}" "$REPORT_FILE"
fi
chmod 600 "$REPORT_FILE"

cat "$REPORT_FILE"

echo ""
log "Report saved to: ${REPORT_FILE}"

apt-get autoremove -y -qq 2>/dev/null
apt-get clean
