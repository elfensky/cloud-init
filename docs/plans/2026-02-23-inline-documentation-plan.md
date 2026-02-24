# Inline Script Documentation — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace external `docs/*.md` with self-contained inline documentation (header summaries + block-level comments with what+why) in all 4 shell scripts.

**Architecture:** Each script gets a comprehensive header comment block (condensed from `docs/*.md`) and block-level inline comments throughout. External docs are deleted. `docs/plans/` is preserved.

**Tech Stack:** Bash scripts, shellcheck for validation

**Design doc:** `docs/plans/2026-02-23-inline-documentation-design.md`

---

### Task 1: Document `lib.sh`

**Files:**
- Modify: `lib.sh` (entire file — add header + inline comments)
- Reference: `docs/lib.md` (for header summary content)

**Step 1: Add header summary block**

Replace the existing 4-line header (`# shellcheck shell=bash` through `# Usage:`) with a comprehensive header block that includes:
- Purpose: shared function library sourced by all init scripts
- Usage: `source "$(dirname "$0")/lib.sh"`
- Double-source guard note
- Function reference table covering: output functions, interactive prompts (return values), validators, system detection (side effects)

Condense content from `docs/lib.md` into this header.

**Step 2: Add inline comments to output functions section (lines ~10-45)**

Document:
- ANSI color code definitions — what each color is used for
- `log/warn/err/info` — note that `err` goes to stderr
- `separator` — visual section divider during script execution
- `banner` — script header with UTC timestamp and hostname
- `print_summary` — formatted key-value table for configuration summaries

**Step 3: Add inline comments to interactive prompts section (lines ~48-214)**

Document for each function:
- `ask_choice` — how it sets REPLY to 1-based index, default handling, validation loop
- `ask_yesno` — return code convention (0=yes, 1=no), case-insensitive matching
- `ask_input` — required value enforcement, optional regex validation
- `ask_password` — silent input via read -s, min length enforcement
- `ask_multiselect` — toggle-based UI, MULTISELECT_RESULT array, confirm-on-empty-Enter

**Step 4: Add inline comments to validation section (lines ~218-254)**

Document what each validator checks and its regex/logic:
- `validate_ip` — regex + octet range 0-255
- `validate_cidr` — IP + prefix length 0-32
- `validate_hostname` — RFC-compliant, max 253 chars
- `validate_username` — Linux naming rules
- `validate_port` — 1-65535
- `validate_ssh_key` — prefix check (not full key validation)

**Step 5: Add inline comments to system detection section (lines ~258-323)**

Document:
- `detect_private_iface` — candidate order and why those specific interfaces
- `detect_ssh_service` — Ubuntu vs other distros naming
- `get_private_ip` — grep -oP pattern for extracting IP
- `require_root/require_ubuntu/require_cmd` — exit behavior
- `generate_token` — 32 bytes hex = 256 bits of entropy

**Step 6: Validate and commit**

Run: `bash -n lib.sh && shellcheck -x lib.sh`
Expected: no errors (comments don't affect syntax)

```bash
git add lib.sh
git commit -m "docs: add inline documentation to lib.sh"
```

---

### Task 2: Document `init.1.vps.sh`

**Files:**
- Modify: `init.1.vps.sh` (entire file — add header + inline comments)
- Reference: `docs/init.1.vps.md` (for header summary content)

**Step 1: Add header summary block**

Replace existing header (lines 1-8) with comprehensive block covering:
- Purpose, usage, idempotent note
- Numbered interactive steps (1-10)
- Side-by-side comparison table: K8s node vs Standalone VPS
- SSH hardening summary (ciphers, rollback behavior)
- Output file, next steps

Condense from `docs/init.1.vps.md`.

**Step 2: Add inline comments to preflight + interactive config (lines ~10-159)**

Document:
- `set -euo pipefail` — what each flag does (exit on error, undefined var, pipe failure)
- `SCRIPT_DIR` resolution — why BASH_SOURCE instead of $0
- Server purpose choice — explain what changes between K8s and standalone
- Hostname validation — why RFC compliance matters
- SSH port — note that non-standard ports aren't real security but reduce log noise
- User creation flow — why key-only auth is required
- Private interface detection — why auto-detect + manual override
- Security tool choice — Fail2ban vs CrowdSec trade-offs
- Tailscale — VPN overlay for management access
- Unattended upgrades — security patches with 04:00 reboot
- Ubuntu Pro — ESM for extended security maintenance
- Confirmation summary — last chance before irreversible changes

**Step 3: Add inline comments to system update + packages (lines ~165-199)**

Document:
- `DEBIAN_FRONTEND=noninteractive` — prevents apt prompts during automated install
- Common packages — why each is included (ca-certificates for HTTPS, jq for JSON, etc.)
- K8s packages — ipset/conntrack for CNI, open-iscsi/nfs-common for storage, auditd for compliance
- `iscsid` enable — required by Longhorn/other iSCSI storage backends

**Step 4: Add inline comments to user creation + SSH hardening (lines ~201-283)**

Document:
- `adduser --disabled-password --gecos ""` — no password login, no GECOS prompts
- `authorized_keys` permissions — 700/600 required by sshd strict mode
- SSH hardening config values — each setting with what+why:
  - PermitRootLogin no — audit trail, reduced attack surface
  - MaxAuthTries 3 — brute-force vs typo balance
  - ClientAliveInterval 300 / CountMax 2 — 10min idle timeout
  - Cipher/MAC/Kex selection — why these specific algorithms
- `sshd -t` validation — test before reload prevents lockout
- SSH verification pause — safety net against lockout
- Rollback mechanism — removes hardening file on failure

**Step 5: Add inline comments to UFW firewall (lines ~285-306)**

Document:
- `ufw --force reset` — clean slate, idempotent
- K8s mode — public interface SSH only, private interface all (cluster traffic)
- Standalone mode — SSH + HTTP + HTTPS only
- Why `--force enable` — non-interactive

**Step 6: Add inline comments to security tool installation (lines ~308-346)**

Document:
- Fail2ban: jail.local values — bantime 3600s (1h), findtime 600s (10min window), maxretry 3, ufw banaction
- CrowdSec: install method (curl | bash), firewall bouncer, optional dashboard enrollment
- Why banaction=ufw — integrates with existing firewall

**Step 7: Add inline comments to kernel/sysctl (lines ~348-430)**

Document K8s sysctl values:
- `bridge-nf-call-iptables/ip6tables` — required for CNI to intercept bridged traffic
- `ip_forward` — pods need to route traffic between nodes
- `inotify` limits — pods create many file watches (e.g. ConfigMap mounts)
- Security sysctls — why disable redirects, enable syncookies

Document standalone sysctl values:
- `rp_filter` — reverse path filtering prevents IP spoofing
- `icmp_echo_ignore_broadcasts` — prevents smurf attacks
- `log_martians` — logs impossible source addresses
- `tcp_syncookies` + backlog — SYN flood protection
- `ip_forward=0` — standalone server is not a router
- `kernel.randomize_va_space=2` — full ASLR

**Step 8: Add inline comments to system config + audit (lines ~432-516)**

Document:
- Swap disable — kubelet requires swap off for accurate resource accounting
- File descriptor limits — 1M for K8s (pods open many connections)
- Core dumps disabled — prevents sensitive data leaking to disk
- Shared memory noexec — prevents code execution from /run/shm
- Cron restriction — only root can manage scheduled tasks
- Journald cap — prevents logs from filling disk
- Audit rules — what each watch does (RKE2 binaries, identity files, sudo)

**Step 9: Add inline comments to unattended upgrades + tailscale + pro + report (lines ~518-620)**

Document:
- APT periodic settings — daily list update, daily upgrade check, weekly autoclean
- Allowed origins — security repos only (not all updates)
- Automatic reboot at 04:00 — low-traffic window
- Tailscale install + UFW allow — management VPN
- Report file — permissions 600, owned by created user

**Step 10: Validate and commit**

Run: `bash -n init.1.vps.sh && shellcheck -x init.1.vps.sh`

```bash
git add init.1.vps.sh
git commit -m "docs: add inline documentation to init.1.vps.sh"
```

---

### Task 3: Document `init.2.rke2.sh`

**Files:**
- Modify: `init.2.rke2.sh` (entire file — add header + inline comments)
- Reference: `docs/init.2.rke2.md` (for header summary content)

**Step 1: Add header summary block**

Comprehensive header covering:
- Purpose, usage, run-per-node after init.1.vps.sh
- Preflight checks (ip_forward, existing RKE2)
- Numbered interactive steps (1-10)
- Node join order (servers one-at-a-time, workers parallel)
- Config file output path
- Next step: init.3.pods.sh

**Step 2: Add inline comments to preflight (lines ~10-46)**

Document:
- `ip_forward` check — confirms init.1.vps.sh was run in K8s mode
- Private interface detection — used for node-ip in config.yaml
- RKE2 running check — warns before reconfiguring a live node

**Step 3: Add inline comments to interactive config (lines ~48-237)**

Document:
- Node role meanings — bootstrap (first, initializes etcd), additional server (joins control plane), worker (no etcd/apiserver)
- Token generation — 256-bit hex token for cluster authentication
- Server URL — why https and port 6443 (k8s API default)
- TLS SANs — needed for kubectl access from external IPs/domains
- CNI selection — Calico (mature, policy-rich), Cilium (eBPF, modern), Canal (hybrid)
- WireGuard — per-CNI implementation differences and maturity
- Advanced options — when to change default CIDRs, etcd metrics exposure, audit logging
- etcd quorum warning — why servers must join one at a time (raft consensus)

**Step 4: Add inline comments to config.yaml generation (lines ~249-312)**

Document:
- Worker vs server config difference — workers are minimal (token, server, node-ip)
- `bind-address` and `advertise-address` — ensures API server listens on private IP only
- TLS SANs in config — must include all IPs/domains used to reach the API server
- `kubelet-arg node-ip` — forces kubelet to use private IP for node registration
- `etcd-expose-metrics` — enables Prometheus scraping of etcd
- Audit log settings — 30 days retention, 10 backups, 100MB max per file
- Custom CIDR logic — only written when non-default to keep config minimal

**Step 5: Add inline comments to WireGuard HelmChartConfig (lines ~320-363)**

Document:
- HelmChartConfig resource — RKE2-specific CRD that customizes built-in Helm charts
- Cilium WireGuard — transparent encryption via eBPF, configured pre-start
- Canal WireGuard — flannel backend swap, less mature
- Calico WireGuard — post-install kubectl patch (cannot pre-configure)
- Why bootstrap only — manifests are only read by the first server

**Step 6: Add inline comments to RKE2 installation + startup (lines ~365-425)**

Document:
- `INSTALL_RKE2_TYPE=agent` — workers install agent binary, not server
- `INSTALL_RKE2_CHANNEL` — pin to specific RKE2 release channel
- `curl | env ... sh` — standard RKE2 install method, env vars control behavior
- systemctl enable + start — persist across reboots
- 300s timeout loop — RKE2 first boot downloads images, can be slow
- 30s extra settle for servers — API server needs time after systemd reports active

**Step 7: Add inline comments to post-install (lines ~427-487)**

Document:
- PATH + KUBECONFIG in .bashrc — persistent kubectl access for root
- `chmod 644 rke2.yaml` — readable by non-root for kubectl access
- Calico WireGuard post-install command — must wait for all nodes
- Next steps per role — different instructions for bootstrap, server, worker

**Step 8: Validate and commit**

Run: `bash -n init.2.rke2.sh && shellcheck -x init.2.rke2.sh`

```bash
git add init.2.rke2.sh
git commit -m "docs: add inline documentation to init.2.rke2.sh"
```

---

### Task 4: Document `init.3.pods.sh`

**Files:**
- Modify: `init.3.pods.sh` (entire file — add header + inline comments)
- Reference: `docs/init.3.pods.md` (for header summary content)

**Step 1: Add header summary block**

Comprehensive header covering:
- Purpose, usage, run once on server node
- Preflight checks (kubectl, cluster connectivity)
- Component selection with dependencies
- Per-component config options
- Proxy Protocol ordering (critical)
- Output: credentials file

**Step 2: Add inline comments to preflight + component selection (lines ~10-93)**

Document:
- PATH/KUBECONFIG export — needed because script runs as root, not interactive shell
- kubectl connectivity test — verifies this is a server node with running RKE2
- NotReady warning — partial cluster can cause failed deployments
- Multi-select defaults — why Rancher is off by default
- Dependency resolution — Rancher needs cert-manager + ingress; monitoring/logging need storage; all charts need Helm

**Step 3: Add inline comments to per-component configuration (lines ~95-207)**

Document:
- ingress-nginx LB IP — used for proxy-real-ip-cidr (trust Proxy Protocol from this IP only)
- Proxy Protocol ordering warning — why order matters (nginx expects headers from first request)
- cert-manager email — required by Let's Encrypt for expiry notices
- ClusterIssuer staging vs prod — rate limits on prod, staging for testing
- Grafana password — auto-generation for convenience
- Grafana issuer — staging first, switch to prod when DNS is verified
- Prometheus retention/storage — 30d/50Gi balances history vs disk
- Loki retention in hours — 336h = 14 days
- Rancher replicas — 3 for HA across control plane nodes

**Step 4: Add inline comments to Helm deployment (lines ~230-247)**

Document:
- Helm install check — idempotent, skip if already present
- Helm install method — official get-helm-3 script

**Step 5: Add inline comments to local-path-provisioner (lines ~249-259)**

Document:
- Raw manifest apply — no Helm chart needed for this simple provisioner
- Default StorageClass annotation — makes it the fallback for PVCs without explicit class
- v0.0.30 pinned version — stable release

**Step 6: Add inline comments to ingress-nginx values (lines ~261-326)**

Document:
- DaemonSet + hostPort — runs on every worker, binds 80/443 directly (no LoadBalancer service)
- `service.enabled: false` — no cloud LB; traffic hits nodes directly via external LB
- nodeSelector worker — only workers handle ingress traffic
- Proxy Protocol settings — `use-proxy-protocol`, `proxy-real-ip-cidr` (LB IP only)
- Security headers — hide-headers, HSTS 1 year with subdomains
- Proxy timeouts — 120s for long-running requests
- SSL protocols — TLS 1.2+ only (1.0/1.1 deprecated)
- Custom log format — includes upstream info and request ID for debugging
- Admission webhooks — validates Ingress resources before applying
- Metrics + ServiceMonitor — Prometheus auto-discovery
- Resource limits — 256Mi cap prevents runaway memory

**Step 7: Add inline comments to cert-manager (lines ~329-388)**

Document:
- CRDs enabled via Helm — `crds.enabled=true` installs CRDs as part of chart
- Webhook wait — cert-manager webhook must be ready before creating ClusterIssuers
- ClusterIssuer vs Issuer — ClusterIssuer works across all namespaces
- ACME HTTP-01 solver — proves domain ownership via HTTP challenge through nginx
- Staging vs prod servers — staging has no rate limits, issues untrusted certs

**Step 8: Add inline comments to monitoring stack (lines ~390-508)**

Document:
- kube-prometheus-stack — bundles Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics
- `serviceMonitorSelectorNilUsesHelmValues: false` — scrape ALL ServiceMonitors, not just the stack's own
- Prometheus storage — PVC for data persistence across restarts
- Alertmanager storage — smaller PVC for alert state
- Grafana persistence — keeps dashboards and settings across pod restarts
- Grafana ingress — TLS via cert-manager annotation
- Loki datasource — pre-configured if logging is also being installed
- Resource requests/limits — right-sized for small-medium clusters
- Default rules — etcd, apiserver, node recording rules for common alerts

**Step 9: Add inline comments to logging stack (lines ~510-561)**

Document:
- Loki SingleBinary mode — simplest deployment, appropriate for single-cluster
- TSDB + filesystem — no object storage required, works with local-path
- Schema v13 — latest Loki schema version
- Retention via compactor — `retention_enabled: true` + `retention_period`
- Gateway disabled — direct access within cluster, no auth needed
- Promtail — DaemonSet that tails container logs and pushes to Loki
- Both in monitoring namespace — co-located with Prometheus/Grafana

**Step 10: Add inline comments to Rancher + final output (lines ~563-630)**

Document:
- Rancher stable chart — production-grade releases only
- Let's Encrypt TLS source — uses cert-manager integration
- Bootstrap password — first-login password, prompted to change
- Replicas — match to number of server nodes for HA
- Credentials file — mode 600 (root only), saved to /root/
- `declare -A CREDENTIALS` — associative array for collecting outputs
- Pod status display — quick verification all pods are starting

**Step 11: Validate and commit**

Run: `bash -n init.3.pods.sh && shellcheck -x init.3.pods.sh`

```bash
git add init.3.pods.sh
git commit -m "docs: add inline documentation to init.3.pods.sh"
```

---

### Task 5: Delete external docs and final commit

**Files:**
- Delete: `docs/lib.md`
- Delete: `docs/init.1.vps.md`
- Delete: `docs/init.2.rke2.md`
- Delete: `docs/init.3.pods.md`

**Step 1: Delete docs**

```bash
rm docs/lib.md docs/init.1.vps.md docs/init.2.rke2.md docs/init.3.pods.md
```

**Step 2: Commit**

```bash
git add -u docs/
git commit -m "docs: remove external docs (now inline in scripts)"
```

---

### Validation Checklist

After all tasks, verify:
- [ ] `bash -n lib.sh && bash -n init.1.vps.sh && bash -n init.2.rke2.sh && bash -n init.3.pods.sh`
- [ ] `shellcheck -x lib.sh init.1.vps.sh init.2.rke2.sh init.3.pods.sh`
- [ ] Each script has a header summary block
- [ ] Block-level comments explain what + why for non-obvious code
- [ ] No `docs/*.md` files remain (only `docs/plans/`)
- [ ] All code behavior is unchanged (comments only)
