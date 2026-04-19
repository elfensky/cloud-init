# cloud-init

A resumable, linear yes/no wizard for provisioning Ubuntu 24.04 servers.

One entry point — `main.sh` — walks you through each capability in order. For each step: one Y/N prompt ("Configure a firewall?"), optional sub-questions, then the action executes immediately. Every step is verified against its canonical config file before the wizard advances. If you Ctrl+C or lose the connection, the next invocation resumes at the first incomplete step.

No "profile" abstraction. You compose your own box by saying yes or no to each capability.

## Requirements

- Ubuntu 24.04 (amd64 or arm64)
- Root (run with `sudo`)
- Outbound internet for package installs
- Optional: a private network reachable between hosts (auto-detected, used for firewall rules, fail2ban ignores, CrowdSec whitelists, and RKE2 inter-node traffic)

## Usage

```bash
git clone https://github.com/elfensky/cloud-init.git /opt/cloud-init
cd /opt/cloud-init

sudo ./main.sh                         # walk the full wizard
sudo ./main.sh --dry-run               # list remaining steps; no changes
sudo ./main.sh --only 25-firewall      # run exactly one step
sudo ./main.sh --redo 24-ssh-harden    # re-run a completed step
sudo ./main.sh --answers FILE --non-interactive   # headless (KEY="VALUE" lines)
```

### Resume behavior

`main.sh` keeps its state in `/run/cloud-init-scripts/state.env` (tmpfs, root-only) for the duration of the run. If the wizard is interrupted (Ctrl+C, lost SSH, failed step), the file stays and the next `sudo ./main.sh` picks up where you left off:

- Completed steps show as `✓ <name> [done at <timestamp>]` and skip.
- Skipped steps (answered `n`) re-prompt so you can reconsider.
- The final `99-finalize` step prints any generated secrets (RKE2 token, Grafana password, CrowdSec bouncer key, Rancher bootstrap) for you to save, then wipes the state file and verifies the wipe.

Caveat: `/run` is tmpfs, so a full reboot clears it. Wait until the wizard finishes before rebooting, or use `--redo` to re-walk specific steps afterwards.

## Step order

The wizard walks `modules/NN-*.sh` in filename-sort order. Each step is gated by its `applies_<name>` — most apply unconditionally, some gate on earlier choices (e.g. Docker firewall only runs if you said yes to Docker).

**Nothing runs silently.** Every step first prints a one- or two-line description of what it does, then asks for permission before making any change. Answer `n` at any prompt and the step is marked skipped in `state.env` and bypassed. Answer `y` to proceed (follow-up steps — like installing nginx after picking nginx at step 50 — default to `y`).

| # | Step | Notes |
|---|------|-------|
| `15` | Network detection | Picks public + (optional) private interface, IP, CIDR. |
| `20` | Hostname | `hostnamectl set-hostname` |
| `21` | Non-root sudo user (+ SSH key) | Lockout guard: refuses to continue if you'd lose SSH access. |
| `22` | Ed25519 outbound keypair | For outbound Git / peer-to-peer SSH. |
| `23` | Base packages | curl, jq, git, htop, etc. |
| `24` | SSH hardening | Drop-in config + secondary-terminal confirm before the daemon reloads. |
| `25` | Host firewall (UFW) | Multi-network-aware: SSH on public only, allow-all on private. |
| `26` | Kernel hardening baseline | Security sysctls. `ip_forward` is set by Docker/RKE2 modules if selected. |
| `27` | Journald cap | 1G / 100M / 7d |
| `28` | Timezone + NTP | UTC + systemd-timesyncd |
| `29` | Unattended upgrades | Security-only patches; optional auto-reboot. |
| `30` | Intrusion detection | None / fail2ban / crowdsec. Both options honor the private network. |
| `33` | Tailscale | Optional |
| `34` | Ubuntu Pro | Optional |
| `40` | Container runtime | Optional: Podman (default — rootless, daemonless) or Docker Engine (from docker.com). If Docker is chosen, sub-prompt picks DOCKER-USER chain rules (step 41) or a provider firewall (e.g. Hetzner Cloud Firewall / AWS SG) as the port-exposure mitigation. |
| `41` | Docker firewall | DOCKER-USER chain rules + `ip_forward=1`. Runs only when step 40 picked Docker **and** the DOCKER-USER mitigation (not the provider-firewall option). Podman doesn't have the UFW-bypass problem. |
| `50` | Host reverse proxy selector | None / OpenResty (default) / nginx / Apache. All three install from upstream repos for latest versions. |
| `51–53` | Install chosen proxy | HTTP-only default vhost with ACME webroot location. Only **OpenResty** (`openresty.org`) ships Lua built-in and gets the CrowdSec L7 Lua bouncer; upstream **nginx** (`nginx.org`) and **Apache** (`ppa:ondrej/apache2`) rely on the host iptables bouncer from step 30 for L3/L4 only. TLS certs + server block are handled by step 54. |
| `54` | TLS certificates | Optional Let's Encrypt. ACME client: certbot or acme.sh. Challenge: HTTP-01 (default) or DNS-01 (for wildcards / private hosts). DNS providers: Cloudflare / Route53 / DigitalOcean / manual. Writes the TLS vhost appropriate to the installed webserver and reloads. |
| `60` | RKE2 preflight | Asks "Install Kubernetes?". All subsequent RKE2 steps gate on the yes. |
| `61` | RKE2 config | Role (bootstrap/server/worker), token, CNI, WireGuard, TLS SANs, audit rules. |
| `62` | RKE2 install | K8s apt packages + sha256-verified installer. |
| `63` | RKE2 service | Starts systemd unit, waits for Node Ready. |
| `64` | RKE2 WireGuard | HelmChartConfig for Cilium/Canal (bootstrap only). |
| `65` | RKE2 post | kubectl profile, Calico WireGuard helper. |
| `70–79` | Platform stack | Helm / local-path / ingress-nginx / cert-manager / monitoring / logging / crowdsec-k8s / rancher / PSS / netpol. Each is its own Y/N. All gate on RKE2 service being up. |
| `99` | Finalize | Prints generated secrets, wipes state, verifies wipe. |

## RKE2 multi-node bring-up

1. First server: `sudo ./main.sh` → say yes at step 60 → role `bootstrap`. Save the cluster token it prints at step 99.
2. Each additional server, **one at a time** (wait for Ready): `sudo ./main.sh` → role `Additional server` → paste the token.
3. Workers can join in parallel: `sudo ./main.sh` → role `Worker`.
4. Once all nodes show `Ready`: on any server run `sudo ./main.sh` again and say yes to the platform-stack modules (70–79).
5. If you enabled Calico WireGuard: `sudo /usr/local/bin/rke2-enable-wireguard`.

## Files

```
main.sh         wizard orchestrator
state.sh        ephemeral-per-run state helpers
lib.sh          shared functions (prompts, validators, detection)
modules/        40 numbered steps
CLAUDE.md       maintainer notes + gotchas
```
