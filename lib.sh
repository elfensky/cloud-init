# shellcheck shell=bash
# lib.sh — Shared functions for init.vps.sh, init.rke2.sh, init.pods.sh
# Source this file; do not execute directly.
# Usage: source "$(dirname "$0")/lib.sh"

# Guard against double-sourcing
[[ -n "${_LIB_SH_LOADED:-}" ]] && return 0
_LIB_SH_LOADED=1

# =============================================================================
# Colors & Output
# =============================================================================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

separator() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

banner() {
    local title="$1"
    local subtitle="${2:-}"
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    printf "${GREEN}║${NC}  %-60s${GREEN}║${NC}\n" "$title"
    if [[ -n "$subtitle" ]]; then
        printf "${GREEN}║${NC}  %-60s${GREEN}║${NC}\n" "$subtitle"
    fi
    printf "${GREEN}║${NC}  %-60s${GREEN}║${NC}\n" "$(date -u '+%Y-%m-%d %H:%M UTC') | $(hostname)"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# =============================================================================
# Interactive Prompts
# =============================================================================

# ask_choice "prompt" default_num "Label|Description" ...
# Sets REPLY to the chosen index (1-based).
ask_choice() {
    local prompt="$1"
    local default="$2"
    shift 2

    local -a labels=()
    local -a descs=()
    local i=1

    for opt in "$@"; do
        labels+=("${opt%%|*}")
        descs+=("${opt#*|}")
        i=$((i + 1))
    done

    echo ""
    echo -e "${BOLD}${prompt}${NC}"
    for i in "${!labels[@]}"; do
        local num=$((i + 1))
        local marker=""
        if [[ "$num" -eq "$default" ]]; then
            marker=" [default]"
        fi
        printf "  ${BOLD}%d)${NC} %-16s— %s%s\n" "$num" "${labels[$i]}" "${descs[$i]}" "$marker"
    done

    while true; do
        read -rp "Choice [${default}]: " input
        input="${input:-$default}"
        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= ${#labels[@]} )); then
            REPLY="$input"
            return 0
        fi
        err "Invalid choice. Enter a number between 1 and ${#labels[@]}."
    done
}

# ask_yesno "prompt" default(y/n)
# Returns 0 for yes, 1 for no.
ask_yesno() {
    local prompt="$1"
    local default="${2:-n}"

    local hint
    if [[ "$default" == "y" ]]; then
        hint="Y/n"
    else
        hint="y/N"
    fi

    while true; do
        read -rp "${prompt} (${hint}): " input
        input="${input:-$default}"
        case "${input,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) err "Please answer y or n." ;;
        esac
    done
}

# ask_input "prompt" default [regex]
# Sets REPLY to the input value.
ask_input() {
    local prompt="$1"
    local default="${2:-}"
    local regex="${3:-}"

    local display_default=""
    if [[ -n "$default" ]]; then
        display_default=" [${default}]"
    fi

    while true; do
        read -rp "${prompt}${display_default}: " input
        input="${input:-$default}"

        if [[ -z "$input" ]]; then
            err "A value is required."
            continue
        fi

        if [[ -n "$regex" ]] && ! [[ "$input" =~ $regex ]]; then
            err "Invalid format."
            continue
        fi

        REPLY="$input"
        return 0
    done
}

# ask_password "prompt" [min_length]
# Sets REPLY to the password value.
ask_password() {
    local prompt="$1"
    local min_length="${2:-0}"

    while true; do
        read -srp "${prompt}: " input
        echo ""

        if [[ ${#input} -lt $min_length ]]; then
            err "Must be at least ${min_length} characters."
            continue
        fi

        REPLY="$input"
        return 0
    done
}

# ask_multiselect "prompt" "Label|Desc|on" ...
# Sets MULTISELECT_RESULT array (0-indexed, values "on" or "off").
ask_multiselect() {
    local prompt="$1"
    shift

    local -a labels=()
    local -a descs=()
    local -a states=()

    for opt in "$@"; do
        IFS='|' read -r label desc state <<< "$opt"
        labels+=("$label")
        descs+=("$desc")
        states+=("${state:-off}")
    done

    local count=${#labels[@]}

    while true; do
        echo ""
        echo -e "${BOLD}${prompt}${NC}"
        for i in "${!labels[@]}"; do
            local num=$((i + 1))
            local mark=" "
            if [[ "${states[$i]}" == "on" ]]; then
                mark="x"
            fi
            printf "  ${BOLD}%d)${NC} [%s] %-28s— %s\n" "$num" "$mark" "${labels[$i]}" "${descs[$i]}"
        done
        echo ""
        read -rp "Toggle number, or Enter to confirm: " input

        if [[ -z "$input" ]]; then
            MULTISELECT_RESULT=("${states[@]}")
            return 0
        fi

        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= count )); then
            local idx=$((input - 1))
            if [[ "${states[$idx]}" == "on" ]]; then
                states[$idx]="off"
            else
                states[$idx]="on"
            fi
        else
            err "Enter a number between 1 and ${count}, or press Enter to confirm."
        fi
    done
}

# =============================================================================
# Validation
# =============================================================================

validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -ra octets <<< "$ip"
    for o in "${octets[@]}"; do
        (( o <= 255 )) || return 1
    done
    return 0
}

validate_cidr() {
    local cidr="$1"
    [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
    local ip="${cidr%/*}"
    local prefix="${cidr#*/}"
    validate_ip "$ip" && (( prefix <= 32 ))
}

validate_hostname() {
    local h="$1"
    [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] && [[ ${#h} -le 253 ]]
}

validate_username() {
    [[ "$1" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

validate_ssh_key() {
    [[ "$1" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2) ]]
}

# =============================================================================
# System Detection
# =============================================================================

# detect_private_iface — sets PRIVATE_IFACE to the first found private interface
detect_private_iface() {
    local candidates=(enp7s0 ens10 ens7 eth1)
    for iface in "${candidates[@]}"; do
        if ip link show "$iface" &>/dev/null; then
            PRIVATE_IFACE="$iface"
            return 0
        fi
    done
    PRIVATE_IFACE=""
    return 1
}

# detect_ssh_service — sets SSH_SERVICE to "ssh" or "sshd"
detect_ssh_service() {
    if systemctl cat ssh.service &>/dev/null; then
        SSH_SERVICE="ssh"
    elif systemctl cat sshd.service &>/dev/null; then
        SSH_SERVICE="sshd"
    else
        SSH_SERVICE=""
        return 1
    fi
    return 0
}

# get_private_ip — sets PRIVATE_IP from the detected interface
get_private_ip() {
    local iface="${1:-${PRIVATE_IFACE:-}}"
    if [[ -z "$iface" ]]; then
        PRIVATE_IP=""
        return 1
    fi
    PRIVATE_IP=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
    [[ -n "$PRIVATE_IP" ]]
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (sudo)."
        exit 1
    fi
}

require_ubuntu() {
    if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        err "This script requires Ubuntu."
        exit 1
    fi
    UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        err "Required command not found: ${cmd}"
        return 1
    fi
}

generate_token() {
    openssl rand -hex 32
}

# =============================================================================
# Summary Box
# =============================================================================

# print_summary "Title" "Key|Value" ...
print_summary() {
    local title="$1"
    shift

    local width=62
    echo ""
    echo -e "${BLUE}┌$(printf '─%.0s' $(seq 1 $width))┐${NC}"
    printf "${BLUE}│${NC} ${BOLD}%-$((width - 1))s${BLUE}│${NC}\n" "$title"
    echo -e "${BLUE}├$(printf '─%.0s' $(seq 1 $width))┤${NC}"

    for pair in "$@"; do
        local key="${pair%%|*}"
        local val="${pair#*|}"
        printf "${BLUE}│${NC}  %-20s %-$((width - 23))s${BLUE}│${NC}\n" "$key" "$val"
    done

    echo -e "${BLUE}└$(printf '─%.0s' $(seq 1 $width))┘${NC}"
    echo ""
}
