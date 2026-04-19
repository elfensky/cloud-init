#!/usr/bin/env bash
# =============================================================================
# init.1.vps.sh — backward-compatibility shim
# =============================================================================
# This file used to contain ~1000 lines of OS-hardening logic. That logic now
# lives in modules/ under numbered sub-scripts (20-hostname.sh, 21-user.sh,
# 22-ssh-keygen.sh, ...), orchestrated by main.sh.
#
# This shim preserves the old entry point so existing runbooks and muscle
# memory keep working. It simply invokes main.sh with the "host" phase, which
# runs OS hardening + profile-specific host setup (docker + webserver for a
# docker host; auditd for a k8s node; just hardening for a bare VPS).
#
# Interactive scope is unchanged for k8s and bare profiles. Docker profile
# is new and additionally walks through Docker + web-server modules.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/main.sh" --phase host "$@"
