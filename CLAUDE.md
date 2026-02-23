# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

Infrastructure scripts and deployment plan for a production **RKE2 Kubernetes cluster on Hetzner Cloud**. This is not a software project with build/test commands — it's operational infrastructure documentation and shell scripts meant to be run on remote Ubuntu 24.04 servers.

## Repository Structure

- `rke2-master-plan.md` — The canonical deployment guide. 15-phase step-by-step plan covering everything from node creation through monitoring, logging, and customer onboarding. **Read this first** for any cluster-related work.
- `prepare-rke2-node.sh` — Original base image prep script (private interface: `ens10`)
- `prepare-rke2-node_1.sh` — Updated version (private interface: `enp7s0`)
- `prepare-rke2-node_2.sh` — Latest version with improved SSH service detection logic
- `vps-init.sh` — Standalone VPS hardening script (not RKE2-specific), interactive, for general Ubuntu servers

## Cluster Architecture

**6-node cluster** behind a Hetzner Load Balancer (167.235.216.217):

- **3 server nodes** (10.0.0.11-13): control plane + etcd
- **3 worker nodes** (10.0.0.21-23): ingress + workloads
- **Networking**: Calico CNI (VXLAN), Pod CIDR `10.42.0.0/16`, Service CIDR `10.43.0.0/16`
- **Dual interface per node**: `eth0` (public, SSH only via UFW) + `enp7s0` (private, all traffic allowed)

**Platform stack**: ingress-nginx (DaemonSet + hostPort + Proxy Protocol) → cert-manager (Let's Encrypt HTTP-01) → Prometheus/Grafana/Alertmanager → Loki/Promtail → Rancher → local-path-provisioner

**Multi-tenant model**: Each customer gets their own namespace with default-deny NetworkPolicies, their own Postgres pod, and an Ingress under `*.apps.yourdomain.com`. Pods are stateless; data lives in per-customer Postgres (backed up via pg_dump).

## Script Conventions

All shell scripts follow these patterns:
- `set -euo pipefail` at the top
- Colored output helpers: `log()` (green), `warn()` (yellow), `err()` (red)
- Root check (`$EUID -ne 0`) before doing anything
- Interface verification before network configuration
- Designed to be **idempotent** (safe to re-run) — configs are overwritten, not appended
- Configuration variables at the top of the script (e.g., `PRIVATE_IFACE`, `SSH_PORT`)

## Key Details to Preserve

- **Proxy Protocol is ON** for LB ports 80/443 but **OFF for 6443** — enabling it on 6443 breaks kubectl and node joining
- The ingress-nginx must be configured to expect Proxy Protocol headers **before** enabling Proxy Protocol on the LB, or all requests get 400 Bad Request
- etcd servers must be joined **one at a time** (quorum sensitivity); workers can join in parallel
- `prepare-rke2-node_2.sh` is the most recent version of the node prep script — it uses `systemctl cat` for SSH service detection instead of `systemctl list-units`
- The `vps-init.sh` sets `net.ipv4.ip_forward = 0` which is correct for standalone VPS but **conflicts with Kubernetes** (the RKE2 scripts set it to 1)

## Working With These Files

These scripts are run via SSH on remote Hetzner servers, not locally. When modifying:
- Test syntax with `bash -n <script>.sh` (or `shellcheck` if available)
- The private interface name varies between Hetzner server types (`ens10` vs `enp7s0`) — always parameterize it
- Placeholder values that must be replaced: `YOUR_SECURE_TOKEN_HERE`, `yourdomain.com`, `your-email@yourdomain.com`, `CHANGE_ME_TO_SOMETHING_SECURE`, `CHANGE_ME_BOOTSTRAP_PASSWORD`
