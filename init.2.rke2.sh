#!/usr/bin/env bash
# =============================================================================
# init.2.rke2.sh — backward-compatibility shim
# =============================================================================
# RKE2 install logic has moved into modules/60-rke2-preflight.sh through
# modules/65-rke2-post.sh. This shim calls main.sh with the rke2 phase.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/main.sh" --phase rke2 "$@"
