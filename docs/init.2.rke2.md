# init.2.rke2.sh — RKE2 Installation

**Run per-node after `init.1.vps.sh`.** Generates `/etc/rancher/rke2/config.yaml` and installs RKE2.

```bash
sudo ./init.2.rke2.sh
```

## Preflight Checks

- Warns if `ip_forward` is not enabled (means `init.1.vps.sh` wasn't run in K8s mode)
- Warns if RKE2 is already running (offers to reconfigure)
- Auto-detects private interface and IP

## Interactive Steps

1. **Node role** — Bootstrap server (first node), Additional server (joins control plane), or Worker
2. **Node private IP** — auto-detected, editable
3. **Hostname**
4. **Cluster token** — Bootstrap auto-generates one (save it!); joining nodes require the existing token
5. **Server URL** (joining nodes only) — e.g. `https://10.0.0.8:6443`
6. **TLS SANs** (server roles) — starts with node IP + hostname, add LB IPs / domains interactively
7. **CNI plugin** — Calico (default), Cilium, or Canal
8. **WireGuard encryption** (server roles) — CNI-specific behavior:
   - Calico: enabled post-install via `kubectl patch felixconfiguration`
   - Cilium: pre-configured via HelmChartConfig manifest
   - Canal: pre-configured via HelmChartConfig (less mature, warned)
9. **Advanced options** — Pod/Service CIDRs, etcd metrics, audit logging, RKE2 channel
10. **Confirmation**

## What It Does

1. Sets hostname
2. Writes `/etc/rancher/rke2/config.yaml` (server config is full; worker config is minimal)
3. Writes HelmChartConfig manifests for WireGuard (bootstrap + Cilium/Canal only)
4. Installs RKE2 via `curl -sfL https://get.rke2.io`
5. Enables and starts `rke2-server` or `rke2-agent`
6. Waits up to 300s for the service to be active (+ 30s settle for servers)
7. Bootstrap only: configures kubectl (PATH, KUBECONFIG in `.bashrc`)

## Node Join Order

**Servers must be joined one at a time** (etcd quorum). The script displays a prominent warning. Wait for `kubectl get nodes` to show Ready before joining the next server. Workers can join in parallel.

## Next Step

After all nodes have joined, run `init.3.pods.sh` on any server node.
