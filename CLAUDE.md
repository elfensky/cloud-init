# CLAUDE.md

Maintainer notes for this repo. User-facing docs are in `README.md`.

This file focuses on the **non-obvious** — contract edges, load-bearing safety pauses, ordering constraints, and pitfalls that aren't visible from the file tree. If you're editing a module, skim the relevant gotcha before touching anything.

---

## Module interface contract

Every `modules/NN-*.sh` defines five functions, snake_cased from the file stem (`25-firewall` → suffix `firewall`; `22-ssh-keygen` → suffix `ssh_keygen`):

| Function | Side effects | When it runs |
|----------|--------------|--------------|
| `applies_<name>` | none | Inline, every time main.sh needs to decide whether to touch this module. |
| `detect_<name>` | reads canonical config files; writes state | Once, immediately before `configure_<name>` in the configure-pass. |
| `configure_<name>` | prompts; writes state | Once, after `detect_`. NEVER writes to disk outside state.env. |
| `check_<name>` | reads system state | Once, before `run_<name>`. Returns 0 → skip run as a no-op. |
| `run_<name>` | writes canonical config files | Once, in the run-pass. Must be idempotent (`cat >` overwrite, never `>>`). |

Each module also has a trailing `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` block so it can run standalone (`./modules/25-firewall.sh`). Standalone invocation does its own `require_root → state_init → detect → configure → check → run`.

### Gotcha: `applies_*` runs BEFORE the module owns PROFILE

`main.sh` runs the configure-pass over **all** modules, re-evaluating `applies_<name>` inline each time. This is deliberate — `10-profile` sets `PROFILE` in its `configure_`, so `applies_docker` / `applies_rke2_*` / `applies_platform_*` can only see it *after* 10 has run. A single up-front filter would see `PROFILE=""` and incorrectly exclude every profile-gated module.

**Rule:** `applies_<name>` may only depend on state set by modules with a strictly smaller NN prefix. Don't depend on state set by your own or later modules — it won't be there yet.

### Gotcha: main.sh filename → function name mapping

`mod_func_suffix` strips the numeric prefix, then replaces `-` with `_`. So:

- `25-firewall` → `firewall`
- `22-ssh-keygen` → `ssh_keygen`
- `52-webserver-apache` → `webserver_apache`

If you rename a module file, rename all five of its functions to match. Otherwise main.sh will fail to find them (no error — it silently skips).

---

## State model

`state.sh` writes `/run/cloud-init-scripts/state.env`. Three non-obvious properties:

1. **Ephemeral.** `/run` is tmpfs. The file also gets `rm -f`'d by `trap state_cleanup EXIT` in main.sh. So secrets never touch persistent disk (good), but also — a crash mid-run leaves a recoverable snapshot *only* until the next reboot (fine for debugging, not for resume-later).
2. **Canonical source of truth is the real config files**, NOT state.env. Modules' `detect_<name>` functions read `/etc/ssh/sshd_config.d/...`, `ufw status`, `cscli bouncers list`, `/etc/rancher/rke2/config.yaml`, etc. to reconstruct state. Sub-scripts invoked standalone don't have state.env and must work from canonical state alone.
3. **`state_set` writes through.** Each call rewrites `$STATE_FILE` atomically (tmp + mv). This is required because modules source each other occasionally and a stale in-memory value would drift from the file that other modules read.

### Gotcha: `--answers FILE` loads BEFORE state_init

When `--answers` is passed, `state_load_answers` sources the file and calls `state_set` for each key. This happens after `state_init`. Values in the answers file override anything state_init seeded; they do NOT override values set by subsequent `configure_<name>` prompts. In `--non-interactive` mode, no prompts happen, so the answers file is authoritative.

---

## Load-bearing safety checks — DO NOT REMOVE

These pauses/warnings exist because specific real-world incidents would otherwise be unrecoverable without console access. Preserve them when editing.

### `24-ssh-harden`: secondary-terminal confirmation

After writing `/etc/ssh/sshd_config.d/99-hardening.conf` and reloading sshd, the module pauses and prompts: *"Have you verified SSH access in another terminal?"*. On `n`, it **rolls back the drop-in file and reloads sshd** before exiting. Removing this pause turns any sshd_config mistake (wrong port, broken PAM stack, typo'd key) into permanent lockout on a remote box. Keep it.

### `25-firewall`: UFW SSH rule ordering

The run function does `ufw --force reset` → `default deny incoming` → **add SSH rule** → allow-all on private → `ufw --force enable`. Reordering to enable UFW before the SSH allow rule locks the operator out mid-script. The SSH rule must land first.

### `63-rke2-service`: etcd quorum, one-at-a-time

Joining a second server node while the first isn't `Ready` yet can split-brain the etcd Raft group. `61-rke2-config` displays the quorum warning at configure time; removing it risks unrecoverable cluster state. Workers are fine to join in parallel (no etcd membership change).

### `72-ingress-nginx`: Proxy Protocol ordering

The chart deploys nginx with `use-proxy-protocol: "true"`. After it's up, the module pauses with *"Enable Proxy Protocol on LB ports 80/443 — DO NOT enable it on port 6443"*. If you enable PP on the LB before nginx is ready, clients get 400s. If you enable it on 6443, kubectl stops working (it doesn't speak PP). Keep the warning.

### `65-rke2-post`: Calico WireGuard is post-install only

For Calico+WireGuard, 64-rke2-wireguard does **not** write a HelmChartConfig (Calico has no pre-install manifest for WG). Instead, 65-rke2-post drops `/usr/local/bin/rke2-enable-wireguard` and tells the operator to run it after **all nodes** have joined. Enabling Calico WG before all nodes have the WG kernel module loaded breaks pod connectivity on the stragglers.

---

## Ordering and gating constraints

- **Module execution order is filename-glob sort.** Don't rename existing modules; renumber carefully if you insert new ones. Gaps in the numbering (e.g. 11–14 are free) are intentional reserve.
- **`10-profile` runs first.** Everything downstream reads `PROFILE`. Don't let anything applies-check before 10.
- **`15-networks` runs before any networking-aware module.** `25-firewall`, `31-fail2ban`, `32-crowdsec-host`, `41-docker-firewall`, `61-rke2-config`, `72-ingress-nginx` all consult `NET_PUBLIC_*` / `NET_PRIVATE_*`.
- **`30-security-choice` runs before 31 and 32.** Sets `SECURITY_TOOL`; 31 applies only if fail2ban, 32 only if crowdsec.
- **`70-helm` runs before any other platform module.** All Helm-based modules assume `helm` is on `$PATH`.
- **`76-crowdsec-k8s` and `72-ingress-nginx`.** If both are selected, 72 (numerically first) installs ingress with the CrowdSec Lua bouncer init container pointing at the crowdsec service. 76 installs the LAPI afterwards. The Lua bouncer's connection retries are forgiving — it tolerates LAPI not being up yet. If you reorder or split these, keep the init container's retry logic or you'll get a crash loop.

### Gotcha: Docker bypasses UFW

Docker's daemon inserts its own `iptables` rules that run **before** the UFW ones. Exposed container ports become reachable from the internet even when UFW default-deny is set. `41-docker-firewall` fixes this by installing explicit rules in the `DOCKER-USER` chain: allow from `NET_PRIVATE_CIDR`, then default-drop. If you skip 41, any `docker run -p 80:80` container is on the public internet regardless of UFW state. Document this in user-facing output.

### Gotcha: K8s ingress is not a choice

`72-ingress-nginx` is the only in-cluster ingress controller; there's no "apache at the K8s layer" option. Reasons: `ingress-apache` is not a maintained mainstream controller; `ingress-nginx` is nginx + Lua (the same engine as OpenResty); the CrowdSec Lua bouncer only plugs into ingress-nginx. The host-level web-server choice (`50-webserver-choice.sh`) is for Docker/bare profiles only.

---

## Conventions

- **Idempotent by overwrite.** Every module that writes a config file uses `cat > file <<EOF` (truncating write), never `>>` (append). Re-running produces identical end state.
- **One responsibility per module.** If a module is doing two unrelated things (e.g. installing nginx *and* setting up a systemd timer), split it. Short files are reviewable.
- **Shared helpers live in `lib.sh`.** Don't reinvent `ask_*`, `validate_*`, `detect_*`, `wait_for`, `require_root`, `ensure_tmux` in modules. Add to `lib.sh` if a pattern reappears.
- **Inline rationale, not WHAT.** Module headers explain *why* a config choice exists (load-bearing reasons, incident history, upstream bug references). Don't repeat what the next five lines of bash obviously do.

## Validation commands

Run before committing any change:

```bash
bash -n main.sh state.sh modules/*.sh
shellcheck -x main.sh state.sh modules/*.sh
```

shellcheck must be clean. The `source`-path directives use `# shellcheck source=/dev/null` because modules source `lib.sh` via a computed variable path (`${MODULE_DIR}/../lib.sh`) that shellcheck can't statically resolve. This is deliberate; don't try to "fix" it with `source-path=SCRIPTDIR` — it breaks when shellcheck is invoked with a changed CWD.

## Git

- **Only commit when asked.** If unclear, ask.
- **Conventional commits.** `feat:` / `fix:` / `chore:` / `refactor:` / `docs:` prefixes. Body in the imperative, one blank line after the subject.
- **Never `--amend` after a pre-commit hook fails.** The commit didn't happen; fix the issue, re-stage, make a new commit.
- **Never force-push main.** Warn the user if they ask.
- **Don't stage unrelated files.** Check `git status` before `git add -A`. In this repo, `.DS_Store` is gitignored; don't include `DONE.MD` or similar working-notes files unless explicitly asked.

## Verification discipline

Report outcomes faithfully. If `shellcheck` fails, say so with the output — do not suppress warnings to manufacture a green run. If you didn't run the target VM and therefore can't confirm runtime behavior, say that — don't imply it "worked" based on static checks alone. Static checks validate *code correctness*, not *feature correctness*.

## File & function size

- Files: aim for under 500 LOC. Split anything over 800.
- Functions: aim for under 100 LOC. Refactor before modifying anything over 200.
- Optimize for cohesion (one responsibility per file) and readability over compactness.

## Large-file reads

When reading files over 500 lines, use `offset` and `limit` with the `Read` tool. A single read of a 1000-line file may truncate.

## Search completeness

When renaming a function / variable / type, search for: direct calls, string literals containing the name, re-exports, barrel files, test mocks. Single grep is insufficient.
