# shellcheck shell=bash
# =============================================================================
# 40-docker.sh — Install Docker CE + compose plugin from the official repo
# =============================================================================
#
# Asks whether to install Docker; on 'yes' sets STEP_docker_SELECTED=yes and
# installs via docker.com's signed-by keyring. Subsequent 41-docker-firewall
# gates on the selection flag and applies the DOCKER-USER chain rules plus
# ip_forward=1 needed for bridge networking.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_docker() { return 0; }

detect_docker() { return 0; }

configure_docker() {
    info "Official docker-ce + compose plugin from docker.com's signed repo."
    info "Step 41 follows and closes the UFW-bypass hole that Docker otherwise opens."
    if ! ask_yesno "Install Docker CE?" "n"; then
        state_mark_skipped docker
        return 0
    fi
    state_set STEP_docker_SELECTED yes

    local user default="n"
    user="$(state_get USER_NAME)"
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

verify_docker() {
    command -v docker >/dev/null 2>&1 \
        && systemctl is-active --quiet docker \
        && docker info >/dev/null 2>&1
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
    configure_docker
    state_skipped docker && exit 0
    check_docker && { log "Docker already installed; skipping."; exit 0; }
    run_docker
    verify_docker || { err "Docker verification failed"; exit 1; }
fi
