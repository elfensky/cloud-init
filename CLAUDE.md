# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

Infrastructure scripts and deployment plan for a production **RKE2 Kubernetes cluster on Hetzner Cloud**. This is not a software project with build/test commands — it's operational infrastructure documentation and shell scripts meant to be run on remote Ubuntu 24.04 servers.

## Scripts

All scripts are transferred together: `scp lib.sh init.*.sh root@<ip>:/root/`

| Script | Purpose | Run on |
|--------|---------|--------|
| `lib.sh` | Shared function library (sourced, not executed) | — |
| `init.1.vps.sh` | Interactive OS hardening (K8s node or standalone VPS) | Every node, first |
| `init.2.rke2.sh` | Interactive RKE2 installation, generates `config.yaml` | Each node after step 1 |
| `init.3.pods.sh` | Interactive platform stack deployment via Helm | Once on a server node after all nodes joined |

The numbered prefix encodes execution order. Detailed docs per script in `docs/`.

## Cluster Architecture

**6-node cluster** behind a Hetzner Load Balancer (167.235.216.217):

- **3 server nodes** (10.0.0.11-13): control plane + etcd
- **3 worker nodes** (10.0.0.21-23): ingress + workloads
- **Networking**: Calico CNI (VXLAN), Pod CIDR `10.42.0.0/16`, Service CIDR `10.43.0.0/16`
- **Dual interface per node**: `eth0` (public, SSH only via UFW) + `enp7s0` (private, all traffic allowed)

**Platform stack**: ingress-nginx (DaemonSet + hostPort + Proxy Protocol) → cert-manager (Let's Encrypt HTTP-01) → Prometheus/Grafana/Alertmanager → Loki/Promtail → Rancher → local-path-provisioner

**Multi-tenant model**: Each customer gets their own namespace with default-deny NetworkPolicies, their own Postgres pod, and an Ingress under `*.apps.yourdomain.com`. Pods are stateless; data lives in per-customer Postgres (backed up via pg_dump).

## Script Conventions

- `set -euo pipefail` at the top
- All output/prompt/validation functions come from `lib.sh` (see `docs/lib.md` for the full API)
- Root check (`require_root`) and Ubuntu check (`require_ubuntu`) before anything
- Designed to be **idempotent** (safe to re-run) — configs are overwritten, not appended
- Every script shows an interactive confirmation summary (`print_summary`) before executing
- Private interface detection tries `enp7s0 → ens10 → ens7 → eth1` in order
- SSH service detection uses `systemctl cat` (handles both `ssh` and `sshd` unit names)

## Key Details to Preserve

- **Proxy Protocol is ON** for LB ports 80/443 but **OFF for 6443** — enabling it on 6443 breaks kubectl and node joining
- The ingress-nginx must be configured to expect Proxy Protocol headers **before** enabling Proxy Protocol on the LB, or all requests get 400 Bad Request
- etcd servers must be joined **one at a time** (quorum sensitivity); workers can join in parallel
- `init.1.vps.sh` handles the ip_forward conflict automatically: "Kubernetes node" mode sets `ip_forward=1`, "Standalone VPS" mode sets `ip_forward=0`
- `init.2.rke2.sh` warns if `ip_forward` is not enabled (i.e., `init.1.vps.sh` wasn't run with K8s mode first)
- SSH hardening validates config with `sshd -t` before reloading and offers rollback if user can't verify access
- Calico WireGuard is a post-install step (`kubectl patch felixconfiguration`); Cilium/Canal WireGuard uses HelmChartConfig manifests placed before RKE2 start

## Working With These Files

These scripts are run via SSH on remote Hetzner servers, not locally. When modifying:
- Test syntax with `bash -n <script>.sh` (or `shellcheck` if available)
- The private interface name varies between Hetzner server types (`ens10` vs `enp7s0`) — always parameterize it
- Placeholder values that must be replaced: `YOUR_SECURE_TOKEN_HERE`, `yourdomain.com`, `your-email@yourdomain.com`, `CHANGE_ME_TO_SOMETHING_SECURE`, `CHANGE_ME_BOOTSTRAP_PASSWORD`
