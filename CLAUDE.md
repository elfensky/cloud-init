# CLAUDE.md

Collection of scripts to automate VPS deployment and hardening.

## Scripts

- `lib.sh` — Shared function library, sourced by all other scripts
- `init.1.vps.sh` — Interactive OS hardening (Kubernetes node or standalone VPS)
- `init.2.rke2.sh` — Interactive RKE2 installation and config generation
- `init.3.pods.sh` — Interactive platform stack deployment via Helm

## Guardrails

- **Remote execution** — Scripts target Ubuntu 24.04 servers via SSH. Validate locally with `bash -n` and `shellcheck -x`.
- **Idempotent** — Configs are overwritten (`cat >`), never appended. Preserve this pattern.
- **Shared library** — All shared functions live in `lib.sh`. Don't duplicate them in individual scripts.
- **Safety checks** — Scripts contain interactive pauses and warnings before dangerous operations (Proxy Protocol ordering, etcd quorum joins, SSH lockout). Never remove these without understanding the consequences documented in the script comments.
