# shellcheck shell=bash
# =============================================================================
# 40-runtime.sh — Container runtime: none / Docker Engine / Podman
# =============================================================================
#
# Offers the two common OCI runtimes:
#
#   Docker Engine — docker.com's `docker-ce` apt package. Large ecosystem
#                   of tools, widely documented. Runs as a root daemon.
#                   Manipulates iptables in a way that bypasses UFW by
#                   default — step 41-docker-firewall closes that hole by
#                   installing rules in the DOCKER-USER chain.
#
#   Podman        — daemonless, rootless-by-default. Drop-in `docker` CLI
#                   compatibility via the podman-docker shim. No iptables
#                   bypass, no persistent root daemon. Ubuntu 24.04 ships
#                   podman 4.x via apt.
#
# Sets CONTAINER_RUNTIME to `docker` / `podman` / `none`. When docker is
# selected, also sets STEP_docker_SELECTED=yes so 41-docker-firewall applies.
# When podman or none is selected, STEP_docker_SELECTED is explicitly
# unset — important on --redo if the operator switches between runs.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_runtime() { return 0; }

detect_runtime() {
    if systemctl is-active --quiet docker 2>/dev/null; then
        state_set CONTAINER_RUNTIME docker
    elif command -v podman >/dev/null 2>&1; then
        state_set CONTAINER_RUNTIME podman
    fi
}

configure_runtime() {
    info "Podman (recommended: daemonless, rootless by default, no UFW-bypass"
    info "footgun) or Docker Engine (wider ecosystem, root daemon). Skip if"
    info "RKE2 (step 60) will be the only container runtime on this host."
    if ! ask_yesno "Install a container runtime (podman/docker)?" "n"; then
        state_set CONTAINER_RUNTIME none
        state_unset STEP_docker_SELECTED 2>/dev/null || true
        state_mark_skipped runtime
        return 0
    fi

    # Podman is idx 1 and the default. Docker is still a first-class option
    # at idx 2 for operators who want/need it.
    local default=1
    case "$(state_get CONTAINER_RUNTIME)" in
        podman) default=1 ;;
        docker) default=2 ;;
    esac
    ask_choice "Container runtime" "$default" \
        "Podman (recommended)|daemonless; rootless by default; drop-in docker CLI via podman-docker" \
        "Docker Engine|docker.com's docker-ce; root daemon; needs step 41 or a provider firewall"
    case "$REPLY" in
        1) _configure_podman ;;
        2) _configure_docker ;;
    esac
}

_configure_docker() {
    state_set CONTAINER_RUNTIME docker
    state_set STEP_docker_SELECTED yes

    local user default="n"
    user="$(state_get USER_NAME)"
    [[ -n "$user" ]] && default="y"
    if [[ -n "$user" ]] && ask_yesno "Add '$user' to the 'docker' group?" "$default"; then
        state_set DOCKER_ADD_USER yes
    else
        state_set DOCKER_ADD_USER no
    fi

    # Docker's daemon inserts iptables rules that bypass UFW, so bound
    # container ports become reachable from the internet unless mitigated.
    # Two ways to handle it:
    info "Docker bypasses UFW by default — bound container ports are"
    info "reachable from the internet unless you mitigate this."
    local fw_default=1
    [[ "$(state_get DOCKER_FIREWALL_MODE)" == "provider" ]] && fw_default=2
    ask_choice "How to control exposed Docker container ports" "$fw_default" \
        "DOCKER-USER chain|Step 41 installs allow-from-private + default-drop rules in the iptables DOCKER-USER chain" \
        "Provider firewall|Skip step 41; you block traffic at the cloud provider (Hetzner Cloud Firewall, AWS SG, GCP/DO Firewall, etc.). Make sure 22/80/443 are open upstream."
    case "$REPLY" in
        1) state_set DOCKER_FIREWALL_MODE docker-user ;;
        2) state_set DOCKER_FIREWALL_MODE provider ;;
    esac
}

_configure_podman() {
    state_set CONTAINER_RUNTIME podman
    # Clear Docker-specific flag so 41-docker-firewall doesn't apply when the
    # operator switches runtimes via --redo.
    state_unset STEP_docker_SELECTED 2>/dev/null || true

    if ask_yesno "Install podman-docker (provides a 'docker' CLI shim for compatibility)?" "y"; then
        state_set PODMAN_DOCKER_SHIM yes
    else
        state_set PODMAN_DOCKER_SHIM no
    fi
    if ask_yesno "Install podman-compose (docker-compose equivalent)?" "y"; then
        state_set PODMAN_COMPOSE yes
    else
        state_set PODMAN_COMPOSE no
    fi
}

check_runtime() {
    case "$(state_get CONTAINER_RUNTIME)" in
        docker) command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker ;;
        podman) command -v podman >/dev/null 2>&1 ;;
        none|*) return 0 ;;
    esac
}

verify_runtime() {
    case "$(state_get CONTAINER_RUNTIME)" in
        docker) command -v docker >/dev/null 2>&1 \
                    && systemctl is-active --quiet docker \
                    && docker info >/dev/null 2>&1 ;;
        podman) command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1 ;;
        none|*) return 0 ;;
    esac
}

_run_docker() {
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

    log "Docker Engine + compose plugin installed"
}

_run_podman() {
    apt-get install -y -qq podman

    [[ "$(state_get PODMAN_DOCKER_SHIM)" == yes ]] \
        && apt-get install -y -qq podman-docker
    [[ "$(state_get PODMAN_COMPOSE)" == yes ]] \
        && apt-get install -y -qq podman-compose

    # Enable the rootless user-mode socket + lingering so tools that rely
    # on DOCKER_HOST or user-service containers keep working after the
    # operator logs out. Only meaningful when a non-root user exists.
    local user
    user="$(state_get USER_NAME)"
    if [[ -n "$user" ]] && id "$user" &>/dev/null; then
        local uid runtime_dir
        uid="$(id -u "$user")"
        runtime_dir="/run/user/${uid}"

        # loginctl enable-linger spawns the user's systemd manager and keeps
        # it alive past logout. The `|| true` is intentional: on some minimal
        # installs linger is already enabled and the call is a no-op error.
        loginctl enable-linger "$user" 2>/dev/null || true

        # sudo -u does NOT create a PAM session, so XDG_RUNTIME_DIR and
        # DBUS_SESSION_BUS_ADDRESS aren't set automatically. Without them,
        # `systemctl --user` fails with "Failed to connect to bus" because
        # it can't locate the per-user systemd manager socket at
        # $XDG_RUNTIME_DIR/systemd/private. Export them explicitly.
        #
        # Real errors surface — no `|| true` swallow — so the operator
        # learns when the user-mode socket didn't come up.
        if sudo -u "$user" \
               XDG_RUNTIME_DIR="$runtime_dir" \
               DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime_dir}/bus" \
               systemctl --user enable --now podman.socket; then
            log "Rootless podman socket enabled for '$user' (${runtime_dir}/podman/podman.sock)"
        else
            warn "podman user socket failed to enable for '$user'."
            warn "Podman itself works; only tools that expect DOCKER_HOST are affected."
            warn "Manual fix as $user:  systemctl --user enable --now podman.socket"
        fi
    fi

    log "Podman installed (rootless by default)"
}

run_runtime() {
    case "$(state_get CONTAINER_RUNTIME)" in
        docker) _run_docker ;;
        podman) _run_podman ;;
        none|"") log "Container runtime: none" ;;
        *)      err "Unknown CONTAINER_RUNTIME=$(state_get CONTAINER_RUNTIME)"; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_runtime
    configure_runtime
    state_skipped runtime && exit 0
    check_runtime && { log "Runtime already installed; skipping."; exit 0; }
    run_runtime
    verify_runtime || { err "Runtime verification failed"; exit 1; }
fi
