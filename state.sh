# shellcheck shell=bash
# =============================================================================
# state.sh — Ephemeral state helpers for main.sh orchestration
# =============================================================================
#
# State lives at /run/cloud-init-scripts/state.env (tmpfs, mode 0600). It is
# populated by the configure-pass of main.sh and consumed by the run-pass.
# A trap in main.sh deletes the file on exit (success or failure); /run is
# tmpfs so it also vanishes on reboot.
#
# Canonical source of truth is always the real config files the modules write
# (sshd_config.d, ufw rules, /etc/crowdsec/*, /etc/rancher/rke2/*, etc.).
# Sub-scripts invoked standalone do NOT rely on this file; they call their
# own detect_<name> function to reconstruct state from the real files.
#
# Usage:
#   source "$(dirname "$0")/state.sh"
#   state_init
#   state_set FIREWALL_MODE standalone
#   mode="$(state_get FIREWALL_MODE default)"
#   state_load_answers /root/answers.env   # optional pre-seed
#   trap state_cleanup EXIT                # set this in main.sh
# =============================================================================

[[ -n "${_STATE_SH_LOADED:-}" ]] && return 0
_STATE_SH_LOADED=1

STATE_DIR="${STATE_DIR:-/run/cloud-init-scripts}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/state.env}"

# Initialize the state directory and (empty) state file. Safe to re-run.
state_init() {
    mkdir -p "$STATE_DIR"
    chmod 0700 "$STATE_DIR"
    [[ -f "$STATE_FILE" ]] || : > "$STATE_FILE"
    chmod 0600 "$STATE_FILE"
}

# Source answers from a user-provided file (pre-seed state). Values override
# anything already in state.env. Used for headless/cloud-init invocation:
#   main.sh --answers /root/answers.env
state_load_answers() {
    local file="$1"
    [[ -z "$file" ]] && { err "state_load_answers: no file given"; return 1; }
    [[ -r "$file" ]] || { err "state_load_answers: cannot read $file"; return 1; }
    # shellcheck source=/dev/null
    source "$file"
    # Persist sourced values into state.env so later module runs see them.
    local key
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        state_set "$key" "${!key}"
    done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$file" | sed 's/=.*//')
}

# Echo the value of KEY if set (non-empty), otherwise DEFAULT. Reads the live
# shell variable; state_set keeps file + shell in sync.
state_get() {
    local key="$1" default="${2:-}"
    if [[ -n "${!key:-}" ]]; then
        printf '%s' "${!key}"
    else
        printf '%s' "$default"
    fi
}

# Set KEY=VALUE in the current shell and write-through to state.env so a crash
# leaves a recoverable snapshot. Uses atomic rewrite (tmp + mv) to avoid
# partial reads by concurrent processes.
state_set() {
    local key="$1" value="$2"
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { err "state_set: invalid key '$key'"; return 1; }

    # Update live shell. printf -v writes into the named variable; the
    # subsequent export makes it visible to sourced module scripts.
    printf -v "$key" '%s' "$value"
    # shellcheck disable=SC2163  # $key holds the variable name, not its value.
    export "$key"

    # Update state.env atomically: read existing (minus this key), append new.
    # printf %q emits a form that bash can re-read safely, handling all
    # metacharacters (quotes, whitespace, backslashes) without hand-escaping.
    [[ -f "$STATE_FILE" ]] || : > "$STATE_FILE"
    local tmp
    tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
    grep -vE "^${key}=" "$STATE_FILE" > "$tmp" || true
    printf "%s=%q\n" "$key" "$value" >> "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

# Remove KEY from state.env and unset the shell variable.
state_unset() {
    local key="$1"
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { err "state_unset: invalid key '$key'"; return 1; }
    unset "$key"
    [[ -f "$STATE_FILE" ]] || return 0
    local tmp
    tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
    grep -vE "^${key}=" "$STATE_FILE" > "$tmp" || true
    chmod 0600 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

# Re-import the state file into the current shell. Safe to call repeatedly.
state_load() {
    [[ -f "$STATE_FILE" ]] || return 0
    # shellcheck source=/dev/null
    source "$STATE_FILE"
}

# Trap handler — called on main.sh exit. Removes the state file and directory.
# Idempotent; safe if state_init was never called.
state_cleanup() {
    rm -f "$STATE_FILE" 2>/dev/null || true
    rmdir "$STATE_DIR" 2>/dev/null || true
}
