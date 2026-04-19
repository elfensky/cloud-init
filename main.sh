#!/usr/bin/env bash
# =============================================================================
# main.sh — Orchestrator for modular VPS / Kubernetes / Docker setup
# =============================================================================
#
# Entry point for the refactored setup scripts. Discovers modules/*.sh,
# runs their applies_/detect_/configure_/run_ functions in numeric order,
# gathers all answers upfront, shows a summary, then executes.
#
# Profiles (picked by 10-profile.sh):
#   k8s     — Kubernetes node (RKE2 + optional platform stack)
#   docker  — Docker host (reverse-proxy VPS for containers)
#   bare    — Hardened VPS, no container runtime
#
# Usage:
#   sudo ./main.sh                       # interactive, all applicable modules
#   sudo ./main.sh --phase host          # OS + security + profile-specific host
#   sudo ./main.sh --phase rke2          # K8s profile: RKE2 install (60-65)
#   sudo ./main.sh --phase platform      # K8s profile: platform stack (70s)
#   sudo ./main.sh --only 25-firewall    # run one module by name
#   sudo ./main.sh --answers FILE        # pre-seed state from a KEY=VALUE file
#   sudo ./main.sh --non-interactive     # skip prompts, require full answers
#   sudo ./main.sh --dry-run             # list what would run; no side effects
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=state.sh
source "${SCRIPT_DIR}/state.sh"

MODULE_DIR="${SCRIPT_DIR}/modules"

# Parse args
PHASE=""
ONLY=""
ANSWERS_FILE=""
NON_INTERACTIVE=0
DRY_RUN=0

usage() {
    sed -n 's/^# \{0,1\}//;2,/^$/p' "${BASH_SOURCE[0]}" | sed -n '1,/^$/p'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase)             PHASE="$2"; shift 2 ;;
        --only)              ONLY="$2"; shift 2 ;;
        --answers)           ANSWERS_FILE="$2"; shift 2 ;;
        --non-interactive)   NON_INTERACTIVE=1; shift ;;
        --dry-run)           DRY_RUN=1; shift ;;
        -h|--help)           usage; exit 0 ;;
        *) err "Unknown argument: $1"; usage; exit 2 ;;
    esac
done

# Map phase names to module-number prefix globs. Modules are profile-gated via
# applies_<name>, so including a number range here only widens the *candidates*;
# ones that don't apply to the current profile are filtered out.
phase_glob() {
    case "$1" in
        # "host" covers everything needed to make the machine useful for its
        # profile: OS hardening (10-39), docker (40s), webserver + audit (50s).
        # For k8s profile, audit (59) belongs here; docker/webserver are gated off.
        # For docker profile, docker + webserver modules run; audit is gated off.
        host|os)   echo "1?-*.sh 2?-*.sh 3?-*.sh 4?-*.sh 5?-*.sh" ;;
        rke2)      echo "6?-*.sh" ;;
        platform)  echo "7?-*.sh" ;;
        all|"")    echo "??-*.sh" ;;
        *) err "Unknown phase: $1"; exit 2 ;;
    esac
}

# Given a module file path, echo its short name (e.g. "25-firewall").
mod_name() {
    local f="$1"
    f="${f##*/}"
    echo "${f%.sh}"
}

# Convert a module name to its snake-case function suffix:
# "25-firewall" -> "firewall"; "22-ssh-keygen" -> "ssh_keygen".
mod_func_suffix() {
    local name="$1"
    # Strip NN- prefix.
    name="${name#*-}"
    # Replace hyphens with underscores.
    echo "${name//-/_}"
}

# Preflight
require_root
require_ubuntu

# tmux session protection — safe if already in tmux or unavailable.
apt-get install -y -qq tmux 2>/dev/null || true
ensure_tmux "$@"

banner "Cloud VPS Setup — main.sh" "Ubuntu ${UBUNTU_VERSION}"

# Set up ephemeral state.
state_init
trap state_cleanup EXIT

# Optional answers pre-seed.
if [[ -n "$ANSWERS_FILE" ]]; then
    info "Loading answers from $ANSWERS_FILE"
    state_load_answers "$ANSWERS_FILE"
fi

# =============================================================================
# Discover modules
# =============================================================================

read -ra GLOB_LIST <<< "$(phase_glob "$PHASE")"
ALL_MODULES=()
for glob in "${GLOB_LIST[@]}"; do
    # Intentional word-splitting for glob expansion.
    for f in "$MODULE_DIR"/$glob; do
        [[ -f "$f" ]] || continue
        ALL_MODULES+=("$f")
    done
done

# --only narrows to a single module.
if [[ -n "$ONLY" ]]; then
    match=""
    for f in "${ALL_MODULES[@]}"; do
        if [[ "$(mod_name "$f")" == "$ONLY" ]]; then
            match="$f"
            break
        fi
    done
    [[ -z "$match" ]] && { err "Module '$ONLY' not found under $MODULE_DIR"; exit 2; }
    ALL_MODULES=( "$match" )
fi

if [[ ${#ALL_MODULES[@]} -eq 0 ]]; then
    warn "No modules matched phase='$PHASE' only='$ONLY'"
    exit 0
fi

# Source every module so its functions are defined in our shell.
for f in "${ALL_MODULES[@]}"; do
    # shellcheck source=/dev/null
    source "$f"
done

# =============================================================================
# Dry-run: list modules whose applies_<name> currently passes.
# (Without running configure_, profile-gated modules will correctly show as
# inactive; that's the nature of a dry run before any answers are given.)
# =============================================================================

if [[ $DRY_RUN -eq 1 ]]; then
    separator "Dry run — modules applicable to the current state"
    for f in "${ALL_MODULES[@]}"; do
        sfx="$(mod_func_suffix "$(mod_name "$f")")"
        if declare -F "applies_${sfx}" >/dev/null && ! "applies_${sfx}"; then
            continue
        fi
        echo "  $(mod_name "$f")"
    done
    exit 0
fi

# =============================================================================
# Configure pass — collect ALL answers before any destructive action.
#
# applies_<name> is re-evaluated inline because earlier modules populate the
# state that later applies_ checks consult (10-profile sets PROFILE; 30-security-
# choice sets SECURITY_TOOL; 50-webserver-choice sets WEBSERVER_KIND; etc.).
# A single up-front filter would see empty state and exclude profile-gated
# modules (40-docker, 60-65 rke2, 70-79 platform) from the run.
# =============================================================================

separator "Configuration"

for f in "${ALL_MODULES[@]}"; do
    sfx="$(mod_func_suffix "$(mod_name "$f")")"
    if declare -F "applies_${sfx}" >/dev/null && ! "applies_${sfx}"; then
        continue
    fi
    if declare -F "detect_${sfx}" >/dev/null; then
        "detect_${sfx}" || true
    fi
    if declare -F "configure_${sfx}" >/dev/null; then
        if [[ $NON_INTERACTIVE -eq 1 ]]; then
            # Honour seeded values; skip prompts. Modules must self-police this.
            export CLOUD_NON_INTERACTIVE=1
        fi
        "configure_${sfx}"
    fi
done

# Build the final ACTIVE list using state as populated by the configure pass.
ACTIVE=()
for f in "${ALL_MODULES[@]}"; do
    sfx="$(mod_func_suffix "$(mod_name "$f")")"
    if declare -F "applies_${sfx}" >/dev/null; then
        "applies_${sfx}" && ACTIVE+=("$f")
    else
        ACTIVE+=("$f")
    fi
done

if [[ ${#ACTIVE[@]} -eq 0 ]]; then
    warn "No applicable modules for profile '$(state_get PROFILE '(unset)')'"
    exit 0
fi

# =============================================================================
# Summary + confirmation
# =============================================================================

if [[ $NON_INTERACTIVE -eq 0 ]]; then
    separator "Summary"
    info "The following modules will run (in order):"
    for f in "${ACTIVE[@]}"; do
        echo "  - $(mod_name "$f")"
    done
    echo ""
    if ! ask_yesno "Proceed with configuration?" "y"; then
        warn "Aborted by operator before any changes were made."
        exit 0
    fi
fi

# =============================================================================
# Run pass — execute in numeric order
# =============================================================================

for f in "${ACTIVE[@]}"; do
    sfx="$(mod_func_suffix "$(mod_name "$f")")"
    separator "Running $(mod_name "$f")"

    # check_<name> short-circuits no-op re-runs.
    if declare -F "check_${sfx}" >/dev/null && "check_${sfx}"; then
        log "$(mod_name "$f") already in desired state — skipping."
        continue
    fi

    if declare -F "run_${sfx}" >/dev/null; then
        "run_${sfx}"
    else
        warn "$(mod_name "$f") has no run_${sfx} function — nothing to do."
    fi
done

separator "Done"
log "All modules completed."
