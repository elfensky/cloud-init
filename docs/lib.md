# lib.sh — Shared Function Library

Sourced by all `init.*.sh` scripts. Not executable on its own.

```bash
source "$(dirname "$0")/lib.sh"
```

Has a double-source guard (`_LIB_SH_LOADED`).

## Output Functions

| Function | Color | Purpose |
|----------|-------|---------|
| `log()` | Green `[OK]` | Success messages |
| `warn()` | Yellow `[WARN]` | Warnings |
| `err()` | Red `[ERROR]` | Errors (to stderr) |
| `info()` | Blue `[INFO]` | Informational |
| `separator(title)` | Blue box | Section headers during execution |
| `banner(title, subtitle?)` | Green box | Script header with timestamp + hostname |
| `print_summary(title, "Key\|Value" ...)` | Blue table | Configuration summaries and reports |

## Interactive Prompts

All prompts set `REPLY` (or noted otherwise) and loop until valid input.

| Function | Returns | Description |
|----------|---------|-------------|
| `ask_choice(prompt, default, "Label\|Desc" ...)` | `REPLY` (1-based index) | Numbered single-select menu |
| `ask_yesno(prompt, default)` | exit code 0=yes, 1=no | Yes/no confirmation |
| `ask_input(prompt, default, regex?)` | `REPLY` | Free-text with optional regex validation |
| `ask_password(prompt, min_length?)` | `REPLY` | Silent input (`read -s`) |
| `ask_multiselect(prompt, "Label\|Desc\|on" ...)` | `MULTISELECT_RESULT` array ("on"/"off") | Toggle-based multi-select |

## Validators

All return exit code 0 (valid) or 1 (invalid).

| Function | Validates |
|----------|-----------|
| `validate_ip(ip)` | IPv4 address (octet range check) |
| `validate_cidr(cidr)` | CIDR notation (e.g. `10.0.0.0/16`) |
| `validate_hostname(h)` | RFC-compliant hostname (max 253 chars) |
| `validate_username(u)` | Linux username (`^[a-z][a-z0-9_-]{0,31}$`) |
| `validate_port(p)` | Port number (1-65535) |
| `validate_ssh_key(key)` | SSH public key prefix (rsa/ed25519/ecdsa) |

## System Detection

These functions set global variables as side effects.

| Function | Sets | Description |
|----------|------|-------------|
| `detect_private_iface()` | `PRIVATE_IFACE` | Tries `enp7s0`, `ens10`, `ens7`, `eth1` in order |
| `detect_ssh_service()` | `SSH_SERVICE` | `"ssh"` or `"sshd"` via `systemctl cat` |
| `get_private_ip(iface?)` | `PRIVATE_IP` | IPv4 from interface (defaults to `PRIVATE_IFACE`) |
| `require_root()` | — | Exits if not root |
| `require_ubuntu()` | `UBUNTU_VERSION` | Exits if not Ubuntu |
| `require_cmd(cmd)` | — | Returns 1 if command missing |
| `generate_token()` | stdout | `openssl rand -hex 32` |
