#!/usr/bin/env bash
# =============================================================================
# init.3.pods.sh — backward-compatibility shim
# =============================================================================
# Platform stack logic has moved into modules/70-helm.sh through
# modules/79-netpol.sh. This shim calls main.sh with the platform phase.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/main.sh" --phase platform "$@"
