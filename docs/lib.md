# lib.sh Function Reference

Shared function library sourced by all init scripts.

## Output

| Function | Description |
|---|---|
| `log MSG` | Print green `[OK]` message to stdout |
| `warn MSG` | Print yellow `[WARN]` message to stdout |
| `err MSG` | Print red `[ERROR]` message to stderr |
| `info MSG` | Print blue `[INFO]` message to stdout |
| `separator TITLE` | Section divider with centered title |
| `banner TITLE [SUBTITLE]` | Top-of-script box with timestamp + hostname |
| `print_summary TITLE KV...` | Key/value summary box (pipe-delimited pairs) |

## Interactive Prompts

| Function | Sets | Description |
|---|---|---|
| `ask_choice PROMPT DEFAULT OPT...` | `REPLY` | Numbered menu (1-based index) |
| `ask_yesno PROMPT [DEFAULT]` | return code | Yes/no (0=yes, 1=no) |
| `ask_input PROMPT [DEFAULT] [REGEX]` | `REPLY` | Free text input |
| `ask_password PROMPT [MIN_LEN]` | `REPLY` | Hidden input |
| `ask_multiselect PROMPT OPT...` | `MULTISELECT_RESULT` | Toggle list ("on"/"off" array) |

## Validators

All return 0=valid, 1=invalid.

| Function | Description |
|---|---|
| `validate_ip IP` | IPv4 address (format + octet range) |
| `validate_cidr CIDR` | IPv4 CIDR (address + /0-32 prefix) |
| `validate_hostname HOST` | RFC-952 hostname (max 253 chars) |
| `validate_username USER` | Linux username (lowercase, max 32 chars) |
| `validate_port PORT` | TCP/UDP port (1-65535) |
| `validate_ssh_key KEY` | Public key prefix (rsa/ed25519/ecdsa) |

## System Detection

| Function | Sets | Description |
|---|---|---|
| `detect_private_iface()` | `PRIVATE_IFACE` | First found private interface (enp7s0, eth1, etc.) |
| `detect_public_iface()` | `PUBLIC_IFACE` | Default-route interface via `ip route` |
| `detect_ssh_service()` | `SSH_SERVICE` | SSH service name ("ssh" or "sshd") |
| `get_private_ip [IFACE]` | `PRIVATE_IP` | Private IP from interface |
| `require_root` | -- | Exits if not root |
| `require_ubuntu` | `UBUNTU_VERSION` | Exits if not Ubuntu |
| `require_cmd CMD` | -- | Returns 1 if CMD not in PATH |
| `generate_token` | stdout | Prints 64 hex chars (256-bit random token) |
