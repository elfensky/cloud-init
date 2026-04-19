# shellcheck shell=bash
# =============================================================================
# 40-docker.sh — Install Docker CE + compose plugin from the official repo
# =============================================================================
#
# Uses docker.com's signed-by keyring + apt source. Only runs on PROFILE=docker.
# The resulting daemon enables iptables NAT for bridge networking — 26-sysctl.sh
# already sets net.ipv4.ip_forward=1 for the docker profile so this works.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_docker() { [[ "$(state_get PROFILE)" == docker ]]; }

detect_docker() { return 0; }

configure_docker() {
    # Let the operator add their non-root user to the docker group.
    local user default
    user="$(state_get USER_NAME)"
    default="n"
    [[ -n "$user" ]] && default="y"
    if [[ -n "$user" ]] && ask_yesno "Add '$user' to the 'docker' group?" "$default"; then
        state_set DOCKER_ADD_USER yes
    else
        state_set DOCKER_ADD_USER no
    fi
}

check_docker() {
    command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker
}

run_docker() {
    local codename
    codename="$(lsb_release -cs)"

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable
EOF

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    systemctl enable docker --now

    if [[ "$(state_get DOCKER_ADD_USER)" == yes ]]; then
        local u
        u="$(state_get USER_NAME)"
        usermod -aG docker "$u"
        log "User '$u' added to docker group (re-login to take effect)"
    fi

    log "Docker CE + compose plugin installed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_docker || { info "Not a docker profile; skipping."; exit 0; }
    configure_docker
    check_docker && { log "Docker already installed; skipping."; exit 0; }
    run_docker
fi
