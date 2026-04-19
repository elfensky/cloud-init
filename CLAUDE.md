# CLAUDE.md

Collection of scripts to automate VPS deployment and hardening.

## Architecture

Entry point is `main.sh`, which orchestrates modular sub-scripts under `modules/`. Three deployment profiles (chosen at runtime by `modules/10-profile.sh`):

- **`k8s`** — Kubernetes node (RKE2 + optional platform stack)
- **`docker`** — Docker host (reverse-proxy VPS running containers)
- **`bare`** — Hardened VPS, no container runtime

### Files

- `main.sh` — Orchestrator. Discovers `modules/NN-*.sh`, runs each module's `applies_*` filter, then a configure-pass (all prompts upfront), then a run-pass. Flags: `--phase {host,rke2,platform}`, `--only NN-name`, `--answers FILE`, `--non-interactive`, `--dry-run`.
- `state.sh` — Ephemeral state helpers. Writes `/run/cloud-init-scripts/state.env` (tmpfs, 0600) during a run; deleted by trap on exit. Canonical source of truth is the actual config files the modules write (sshd_config.d, ufw, /etc/crowdsec/..., /etc/rancher/rke2/...).
- `lib.sh` — Shared function library (ask_*, validate_*, detect_*, wait_for, ensure_tmux, banner). See its header for the full function reference.
- `modules/` — 40 numbered modules, one phase per file.

### Usage

```bash
sudo ./main.sh                         # interactive; runs all modules applicable to the chosen profile
sudo ./main.sh --phase host            # OS hardening + security + profile-host (docker / webserver / audit)
sudo ./main.sh --phase rke2            # K8s profile: RKE2 install
sudo ./main.sh --phase platform        # K8s profile: Helm stack
sudo ./main.sh --only 25-firewall      # run one module
sudo ./main.sh --dry-run               # list what would run
sudo ./main.sh --answers FILE --non-interactive   # headless; FILE pre-seeds state with KEY=VALUE lines
```

Headless `KEY` names are whatever the modules set via `state_set` — grep the `modules/*.sh` for `state_set` to enumerate them.

### Module numbering

| Range | Purpose | Profile gating |
|-------|---------|----------------|
| 10    | Profile selector | all |
| 15    | Network detection (public + private iface/CIDR) | all |
| 20–29 | OS hardening (hostname, user, ssh-keygen, packages, ssh-harden, firewall, sysctl, journald, timezone, unattended) | all |
| 30–34 | Host security add-ons (fail2ban/crowdsec, tailscale, ubuntu-pro) | all |
| 40–41 | Docker install + DOCKER-USER firewall | docker |
| 50–53 | Web server (nginx/apache/openresty) | docker, bare |
| 59    | auditd rules | k8s |
| 60–65 | RKE2 (preflight, config, install, service, wireguard, post) | k8s |
| 70–79 | Platform stack (helm, local-path, ingress-nginx, cert-manager, monitoring, logging, crowdsec, rancher, pss, netpol) | k8s |

### Module interface contract

Every `modules/NN-*.sh` exposes four functions (snake_case suffix derived from the file stem — `25-firewall` → `firewall`):

- `applies_<name>` — returns 0 if this module applies given PROFILE and earlier selections. main.sh filters the active set up front.
- `detect_<name>` — reads canonical config files to reconstruct state. Used for standalone re-runs and for populating prompt defaults.
- `configure_<name>` — interactive prompts; writes to state.env. No side effects.
- `check_<name>` — returns 0 if the system is already in the desired state (run is skipped).
- `run_<name>` — the actual work. Reads only from state.env. Must be idempotent (overwrite files with `cat >`, never append).

Each module's trailing `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` block lets it run standalone; it does its own detect + configure + run without needing main.sh.

### Multi-network awareness

`15-networks.sh` detects public and private interfaces/CIDRs and writes `NET_PUBLIC_*`, `NET_PRIVATE_*`, `NET_HAS_PRIVATE` to state. Downstream modules consult these:

- `25-firewall`: public SSH + (optional) HTTP/HTTPS, allow-all on private.
- `31-fail2ban`: adds `NET_PRIVATE_CIDR` to `ignoreip`.
- `32-crowdsec-host`: drops a whitelist parser for the private CIDR.
- `41-docker-firewall`: DOCKER-USER chain allows from private, default-drops public.
- `61-rke2-config`: binds API server to private IP; adds private to TLS SANs.

If `NET_HAS_PRIVATE=no`, all private-net branches collapse away and behaviour matches today's single-network defaults.

### K8s ingress controller choice — intentionally absent

`ingress-nginx` is installed in `72-ingress-nginx.sh` and is NOT swappable with Apache/OpenResty at the K8s layer. Reasons: `ingress-apache` is not a maintained mainstream controller; `ingress-nginx` IS nginx + Lua (the same engine as OpenResty); the CrowdSec Lua bouncer already injects into the same chart. The host-level web-server choice (`50-webserver-choice.sh`) is for Docker/bare profiles only.

## Git

- **Auto-commit** — After completing a user request that modifies files, create a git commit with a descriptive conventional commit message. Do not push.

## Guardrails

- **Remote execution** — Scripts target Ubuntu 24.04 servers via SSH. Validate locally with `bash -n` and `shellcheck -x`.
- **Idempotent** — Configs are overwritten (`cat >`), never appended. Preserve this pattern.
- **Shared library** — All shared functions live in `lib.sh`. Don't duplicate them in individual scripts.
- **Safety checks** — Scripts contain interactive pauses and warnings before dangerous operations (Proxy Protocol ordering, etcd quorum joins, SSH lockout). Never remove these without understanding the consequences documented in the script comments.


## Verification

Report outcomes faithfully: if tests fail, say so with the relevant output; if you did not run a verification step, say that rather than implying it succeeded. Never claim "all tests pass" when output shows failures, never suppress or simplify failing checks (tests, lints, type errors) to manufacture a green result, and never characterize incomplete or broken work as done.

After completing edits, run the project's test/typecheck/lint commands before reporting success. If none are configured, say so explicitly.

## Large Files

When reading files over 500 lines, use offset and limit parameters to read in chunks. Don't assume a single read captured the entire file.

## Search Completeness

When renaming or changing a function/type/variable, search for: direct calls, type references, string literals containing the name, re-exports, barrel files, and test mocks. Don't assume a single grep found everything.

## File & Function Size

- Prefer files under 500-800 LOC; split files over 1000 LOC before making major changes
- Prefer functions under 100 lines; refactor functions over 200 lines before modifying
- Prioritize cohesion (one responsibility per file), clear boundaries, and readability over compactness