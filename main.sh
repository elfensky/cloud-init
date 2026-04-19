#!/usr/bin/env bash
# =============================================================================
# main.sh — Linear yes/no wizard for VPS / Docker / Kubernetes setup
# =============================================================================
#
# Walks modules/NN-*.sh in filename-sort order. For each module:
#   1. applies_<name> gate — re-evaluated every iteration, so it can consult
#      state that EARLIER modules set (e.g. STEP_rke2_SELECTED gates 61-65).
#   2. If STEP_<name>_COMPLETED=yes and --redo didn't list it → print
#      "✓ [done at <ts>]" and continue.
#   3. detect_<name> — populate state from canonical config files.
#   4. configure_<name> — module asks its own top-level y/n (+ sub-questions).
#      If the operator declines, configure_ calls state_mark_skipped <name>
#      and returns; main.sh sees the flag and moves on.
#   5. run_<name> — execute immediately. Per-step safety pauses live here.
#   6. verify_<name> (or check_<name> as fallback) — read canonical state
#      to confirm the action landed. If it fails, HALT the wizard (exit 1);
#      state is preserved so the next invocation resumes at this step.
#   7. Mark step completed with an ISO timestamp, move to next.
#
# State lives at /run/cloud-init-scripts/state.env for the full run. It
# survives Ctrl+C / lost connections / failed steps, so re-running resumes
# at the first incomplete step. The terminal 99-finalize.sh step prints
# generated secrets to stdout and wipes the state file.
#
# Usage:
#   sudo ./main.sh                       # walk the full wizard
#   sudo ./main.sh --only 25-firewall    # run exactly one step
#   sudo ./main.sh --redo 24-ssh-harden  # clear completion flag and rerun
#   sudo ./main.sh --answers FILE        # pre-seed state from KEY=VALUE file
#   sudo ./main.sh --non-interactive     # no prompts; require seeded answers
#   sudo ./main.sh --dry-run             # list remaining steps; no changes
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=state.sh
source "${SCRIPT_DIR}/state.sh"

MODULE_DIR="${SCRIPT_DIR}/modules"

# Capture argv before the parsing loop shifts it away — ensure_tmux re-execs
# the script inside tmux and needs the operator's original flags.
ORIG_ARGS=("$@")

# Flags
ONLY=""
REDO=""
ANSWERS_FILE=""
NON_INTERACTIVE=0
DRY_RUN=0

usage() {
    sed -n '3,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)            ONLY="$2"; shift 2 ;;
        --redo)            REDO="$2"; shift 2 ;;
        --answers)         ANSWERS_FILE="$2"; shift 2 ;;
        --non-interactive) NON_INTERACTIVE=1; shift ;;
        --dry-run)         DRY_RUN=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) err "Unknown argument: $1"; usage; exit 2 ;;
    esac
done

# Given a module file path, echo its short name: "/x/25-firewall.sh" → "25-firewall".
mod_name() {
    local f="$1"
    f="${f##*/}"
    echo "${f%.sh}"
}

# Echo the function-suffix for a module short-name:
# "25-firewall" → "firewall"; "22-ssh-keygen" → "ssh_keygen".
mod_func_suffix() {
    local name="$1"
    name="${name#*-}"
    echo "${name//-/_}"
}

# Preflight
require_root
require_ubuntu

# tmux session protection. Re-execs inside tmux (if available) and forwards
# the operator's original argv so --redo / --answers / etc. are preserved.
ensure_tmux ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}

banner "Cloud VPS Setup — main.sh" "Ubuntu ${UBUNTU_VERSION}"

# Initialize the state file. If one already exists (previous run Ctrl+C'd),
# load its contents so the wizard resumes at the first incomplete step.
state_init
state_load

# Optional --answers pre-seed. Values in the file override current state.
if [[ -n "$ANSWERS_FILE" ]]; then
    info "Loading answers from $ANSWERS_FILE"
    state_load_answers "$ANSWERS_FILE"
fi

# Apply --redo by clearing completion flags on the listed steps. Accepts
# comma-separated step names (module stems without the .sh).
if [[ -n "$REDO" ]]; then
    IFS=',' read -ra REDO_LIST <<< "$REDO"
    for step in "${REDO_LIST[@]}"; do
        sfx="$(mod_func_suffix "$step")"
        state_clear_step "$sfx"
        info "Cleared completion flag for $step"
    done
fi

# -----------------------------------------------------------------------------
# Discover modules
# -----------------------------------------------------------------------------

ALL_MODULES=()
for f in "$MODULE_DIR"/??-*.sh; do
    [[ -f "$f" ]] || continue
    ALL_MODULES+=("$f")
done

if [[ -n "$ONLY" ]]; then
    match=""
    for f in "${ALL_MODULES[@]}"; do
        if [[ "$(mod_name "$f")" == "$ONLY" ]]; then
            match="$f"; break
        fi
    done
    [[ -z "$match" ]] && { err "Module '$ONLY' not found under $MODULE_DIR"; exit 2; }
    ALL_MODULES=( "$match" )
fi

if [[ ${#ALL_MODULES[@]} -eq 0 ]]; then
    warn "No modules found in $MODULE_DIR"
    exit 0
fi

# Source every module so its functions (applies_, detect_, configure_, run_,
# verify_, check_) are defined in our shell.
for f in "${ALL_MODULES[@]}"; do
    # shellcheck source=/dev/null
    source "$f"
done

# -----------------------------------------------------------------------------
# Dry run: enumerate remaining steps
# -----------------------------------------------------------------------------

if [[ $DRY_RUN -eq 1 ]]; then
    separator "Dry run — step status"
    for f in "${ALL_MODULES[@]}"; do
        name="$(mod_name "$f")"
        sfx="$(mod_func_suffix "$name")"
        if declare -F "applies_${sfx}" >/dev/null && ! "applies_${sfx}"; then
            continue
        fi
        if state_completed "$sfx"; then
            echo "  ✓ $name  [done at $(state_get "STEP_${sfx}_COMPLETED_AT")]"
        elif state_skipped "$sfx"; then
            echo "  ⊘ $name  [skipped]"
        else
            echo "  … $name  [pending]"
        fi
    done
    exit 0
fi

# -----------------------------------------------------------------------------
# Walk the wizard
# -----------------------------------------------------------------------------

for f in "${ALL_MODULES[@]}"; do
    name="$(mod_name "$f")"
    sfx="$(mod_func_suffix "$name")"

    # applies_<name> gates against state set by earlier steps (e.g.
    # STEP_rke2_SELECTED). Re-evaluated each iteration so the gate sees the
    # most recent state.
    if declare -F "applies_${sfx}" >/dev/null && ! "applies_${sfx}"; then
        continue
    fi

    # Completed steps are shown and skipped. --redo already cleared the ones
    # the operator wants to rerun.
    if state_completed "$sfx"; then
        log "✓ $name  [done at $(state_get "STEP_${sfx}_COMPLETED_AT")]"
        continue
    fi

    separator "Step: $name"

    # detect_ reads canonical config to populate defaults for configure_ prompts.
    if declare -F "detect_${sfx}" >/dev/null; then
        "detect_${sfx}" || true
    fi

    # Modules that MUST always run (network detection at 15, finalize at 99)
    # don't wrap their configure_ in an ask_yesno; they just do their work.
    # Everything else asks its own Y/N inside configure_ and either proceeds
    # or calls state_mark_skipped — main.sh checks that flag below.
    if declare -F "configure_${sfx}" >/dev/null; then
        if [[ $NON_INTERACTIVE -eq 1 ]]; then
            export CLOUD_NON_INTERACTIVE=1
            # Module decides whether to prompt or use seeded state.
        fi
        "configure_${sfx}"

        # Modules set STEP_<sfx>_SKIPPED=yes in configure_ when the operator
        # declined the top-level ask_yesno. Honour that.
        if state_skipped "$sfx"; then
            log "⊘ $name — skipped by operator"
            continue
        fi
    fi

    # Execute. Per-step safety pauses (SSH secondary terminal, etcd quorum,
    # Proxy Protocol ordering) live inside the module's run_.
    if declare -F "run_${sfx}" >/dev/null; then
        if ! "run_${sfx}"; then
            err "$name — run_ failed. Fix the underlying issue and re-run main.sh to resume."
            exit 1
        fi
    else
        warn "$name — no run_ function; nothing executed"
    fi

    # Verify. A module's verify_ (or check_ as fallback) MUST confirm the
    # action persisted to the canonical config. If verification fails, the
    # step is NOT marked completed and the wizard halts.
    verify_fn=""
    if declare -F "verify_${sfx}" >/dev/null; then
        verify_fn="verify_${sfx}"
    elif declare -F "check_${sfx}" >/dev/null; then
        verify_fn="check_${sfx}"
    fi

    if [[ -n "$verify_fn" ]]; then
        if ! "$verify_fn"; then
            err "$name — verification failed. The action ran but the canonical"
            err "config does not reflect the expected state."
            err "Investigate, then re-run main.sh (or main.sh --redo $name)."
            exit 1
        fi
    else
        warn "$name — no verify_ or check_ function; step marked completed without verification"
    fi

    state_mark_completed "$sfx"
    log "$name — done"
done

separator "Wizard complete"
log "All applicable steps finished."
