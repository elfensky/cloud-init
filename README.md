# cloud-init

Modular VPS / Kubernetes / Docker setup scripts for Ubuntu 24.04.

One entry point (`main.sh`) drives 40 numbered modules. Pick a profile, answer a set of prompts up front, confirm, then the whole box gets provisioned in one pass.

## Profiles

| Profile | What you get |
|---------|--------------|
| `k8s`    | Hardened OS + RKE2 node + optional platform stack (ingress-nginx, cert-manager, monitoring, logging, CrowdSec, Rancher). |
| `docker` | Hardened OS + Docker CE + reverse-proxy web server (nginx / apache / openresty) + UFW + DOCKER-USER chain rules. |
| `bare`   | Hardened OS. Optional web server. |

All three share OS hardening (SSH key-only auth, UFW, sysctl, fail2ban or CrowdSec, unattended upgrades, optional Tailscale, optional Ubuntu Pro).

## Requirements

- Ubuntu 24.04 (amd64 or arm64)
- Root (run with `sudo`)
- Outbound internet for package installs
- For `k8s` multi-node: a private network reachable between nodes

## Usage

```bash
# Clone
git clone https://github.com/elfensky/cloud-init.git /opt/cloud-init
cd /opt/cloud-init

# Interactive — answers every prompt, previews the summary, then runs.
sudo ./main.sh

# Run a specific phase only.
sudo ./main.sh --phase host       # OS + security + profile-specific host setup
sudo ./main.sh --phase rke2       # K8s profile: RKE2 install and join
sudo ./main.sh --phase platform   # K8s profile: Helm stack on a server node

# Run exactly one module.
sudo ./main.sh --only 25-firewall
sudo ./main.sh --only 22-ssh-keygen

# List what would execute without doing anything.
sudo ./main.sh --dry-run
```

### Headless / cloud-init mode

Pre-seed answers in a `KEY="VALUE"` file and pass `--non-interactive`:

```bash
sudo ./main.sh --answers /root/answers.env --non-interactive
```

State keys used by the modules are declared via `state_set` calls; enumerate them with:

```bash
grep -h 'state_set ' modules/*.sh | awk '{print $2}' | sort -u
```

## Module map

| Range | Purpose | Profile gating |
|-------|---------|----------------|
| `10`    | Profile selector | all |
| `15`    | Network detection (public + private iface/CIDR) | all |
| `20–29` | OS hardening (hostname, user, ssh-keygen, packages, ssh-harden, firewall, sysctl, journald, timezone, unattended) | all |
| `30–34` | Host security (fail2ban XOR crowdsec, tailscale, ubuntu-pro) | all |
| `40–41` | Docker install + DOCKER-USER firewall | docker |
| `50–53` | Web server (nginx / apache / openresty) | docker, bare |
| `59`    | auditd rules | k8s |
| `60–65` | RKE2 (preflight, config, install, service, wireguard, post) | k8s |
| `70–79` | Platform stack (helm, local-path, ingress-nginx, cert-manager, monitoring, logging, crowdsec, rancher, PSS, netpol) | k8s |

## RKE2 multi-node bring-up

1. On the first server: `sudo ./main.sh` → pick `k8s` → role `bootstrap`. Save the cluster token it prints.
2. On each additional server, **one at a time**, wait for the previous node to show `Ready` before starting: `sudo ./main.sh` → role `Additional server` → paste the token.
3. Workers can join in parallel: `sudo ./main.sh` → role `Worker`.
4. After all nodes are `Ready`, on any server run `sudo ./main.sh --phase platform` to deploy the Helm stack.
5. If you enabled Calico WireGuard: `sudo /usr/local/bin/rke2-enable-wireguard`.

## Files

```
main.sh         orchestrator
state.sh        ephemeral state helpers (/run/cloud-init-scripts/state.env)
lib.sh          shared functions (prompts, validators, detection)
modules/        40 numbered modules
CLAUDE.md       maintainer notes and gotchas
```

## License

No license specified — treat as source-available, all rights reserved unless you add one.
