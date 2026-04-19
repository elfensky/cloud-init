# shellcheck shell=bash
# =============================================================================
# 66-ssh-peers.sh — Authorize other servers to SSH into this host
# =============================================================================
#
# Multi-node setups often need inter-host SSH for administrative tasks:
# running kubectl from one node to another, rsync, backup pulls, cluster
# bootstrap scripts. This step appends public keys from peer machines to
# this host's authorized_keys so those peers can SSH in without a later
# ssh-copy-id round trip.
#
# Gated on RKE2 selection. Single-node hosts typically don't need inbound
# SSH from other automated peers; non-k8s multi-VPS setups (separate
# DB server etc.) can still add keys manually via ssh-copy-id later.
#
# Owner: same resolution as 22-ssh-keygen — primary non-root user
# (USER_NAME) if set, else root.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_ssh_peers() {
    [[ "$(state_get STEP_rke2_SELECTED no)" == "yes" ]]
}

_peers_owner() {
    local u
    u="$(state_get USER_NAME)"
    if [[ -n "$u" ]] && id "$u" &>/dev/null; then
        echo "$u"
    else
        echo "root"
    fi
}

_peers_home_for() {
    local u="$1"
    if [[ "$u" == "root" ]]; then echo "/root"
    else echo "/home/$u"
    fi
}

detect_ssh_peers() {
    state_set SSH_PEERS_OWNER "$(_peers_owner)"
}

configure_ssh_peers() {
    local owner home
    owner="$(state_get SSH_PEERS_OWNER)"
    home="$(_peers_home_for "$owner")"

    info "Multi-node setups often need inbound SSH for kubectl, rsync, backups."
    info "Pasted keys are appended to ${home}/.ssh/authorized_keys."

    if ! ask_yesno "Allow other servers to SSH into this host now?" "n"; then
        state_mark_skipped ssh_peers
        return 0
    fi

    local peers="" line
    info "Paste one SSH public key per line. Blank line to finish:"
    while IFS= read -r line; do
        [[ -z "$line" ]] && break
        if validate_ssh_key "$line"; then
            peers+="${line}"$'\n'
        else
            warn "Rejected (not a valid SSH public key): ${line:0:60}..."
        fi
    done

    if [[ -z "$peers" ]]; then
        warn "No valid peer keys entered — skipping."
        state_mark_skipped ssh_peers
        return 0
    fi
    state_set SSH_PEERS_PUBKEYS "$peers"
}

check_ssh_peers() { return 1; }  # State is additive; re-run always safe.

verify_ssh_peers() {
    local owner home auth peers
    owner="$(state_get SSH_PEERS_OWNER)"
    home="$(_peers_home_for "$owner")"
    auth="${home}/.ssh/authorized_keys"
    [[ -f "$auth" ]] || return 1

    peers="$(state_get SSH_PEERS_PUBKEYS)"
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        grep -qxF "$line" "$auth" || return 1
    done <<< "$peers"
    return 0
}

run_ssh_peers() {
    local owner peers home ssh_dir auth
    owner="$(state_get SSH_PEERS_OWNER)"
    peers="$(state_get SSH_PEERS_PUBKEYS)"
    home="$(_peers_home_for "$owner")"
    ssh_dir="${home}/.ssh"
    auth="${ssh_dir}/authorized_keys"

    mkdir -p "$ssh_dir"
    touch "$auth"
    local line
    # Dedupe on append: re-runs must be idempotent per CLAUDE.md.
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        grep -qxF "$line" "$auth" 2>/dev/null || printf '%s\n' "$line" >> "$auth"
    done <<< "$peers"
    chmod 600 "$auth"
    chmod 700 "$ssh_dir"
    chown -R "${owner}:${owner}" "$ssh_dir"
    log "Peer pubkeys installed into $auth"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_ssh_peers
    configure_ssh_peers
    state_skipped ssh_peers && exit 0
    run_ssh_peers
    verify_ssh_peers || { err "ssh-peers verification failed"; exit 1; }
fi
