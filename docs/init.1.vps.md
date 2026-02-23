# init.1.vps.sh — OS Hardening

**Run first on every node.** Interactive script that hardens a fresh Ubuntu 24.04 server for either Kubernetes or standalone use.

```bash
sudo ./init.1.vps.sh
```

## Interactive Steps

1. **Server purpose** — "Kubernetes node" or "Standalone VPS" (controls kernel params, swap, firewall rules)
2. **Hostname**
3. **SSH port** (default: 22)
4. **Non-root sudo user** — username + SSH public key
5. **Private interface** (K8s only) — auto-detects via `detect_private_iface()`, asks for confirmation
6. **Security tool** — Fail2ban (default) or CrowdSec (with optional dashboard enrollment)
7. **Tailscale VPN** (optional)
8. **Unattended security upgrades** (default: yes, reboots at 04:00)
9. **Ubuntu Pro** (optional)
10. **Confirmation** — shows summary, requires explicit yes

## What It Does

| Step | Kubernetes Node | Standalone VPS |
|------|----------------|----------------|
| Packages | Common + `ipset conntrack socat open-iscsi nfs-common auditd` | Common only |
| Kernel | `overlay br_netfilter nf_conntrack` + ip_forward=1 | ip_forward=0, rp_filter=1, martians |
| Swap | Disabled | Unchanged |
| UFW | SSH on eth0 only, all traffic on private iface | SSH + HTTP + HTTPS |
| Audit | RKE2 binary/config watches, identity, sudo, cron | None |
| Limits | nofile 1048576 | Core dumps disabled |
| Shared memory | Unchanged | `noexec,nosuid` on `/run/shm` |

Both modes get: SSH hardening (key-only, no root, rate-limited), journald capping (1G/7d), UTC timezone, NTP.

## SSH Hardening Details

Writes `/etc/ssh/sshd_config.d/99-hardening.conf` with:
- Key-only auth, no root login, max 3 auth tries
- Restricted ciphers (aes256-gcm, chacha20-poly1305), MACs (hmac-sha2-512/256-etm), KexAlgorithms (curve25519)
- Validates config with `sshd -t` before reloading — **rolls back on failure**
- If a user was created, **pauses and asks you to verify SSH access in a new terminal** before continuing (rollback available)

## Output

Saves a report to `~/init-report.txt` (owned by the created user, or root).

## Next Step

- **Kubernetes**: Run `init.2.rke2.sh`
- **Standalone**: Server is ready for application deployment
