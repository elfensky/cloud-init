# init.3.pods.sh — Platform Stack Deployment

**Run once on a server node after all nodes have joined.** Deploys the platform stack via Helm.

```bash
sudo ./init.3.pods.sh
```

## Preflight Checks

- Verifies `kubectl` is available and can connect to the cluster
- Shows current node status, warns about NotReady nodes

## Component Selection

Multi-select menu with automatic dependency resolution:

| Component | Default | Dependencies |
|-----------|---------|-------------|
| Helm | on | Required by all Helm charts (auto-enabled) |
| local-path-provisioner | on | Required by Monitoring/Logging (auto-enabled) |
| ingress-nginx | on | Required by Rancher (auto-enabled) |
| cert-manager | on | Required by Rancher (auto-enabled) |
| Monitoring (Prometheus + Grafana + Alertmanager) | on | Needs storage |
| Logging (Loki + Promtail) | on | Needs storage |
| Rancher | **off** | Needs cert-manager + ingress-nginx |

## Per-Component Configuration

### ingress-nginx
- LB private IP (default: `10.0.0.8`) — used for `proxy-real-ip-cidr`
- Deployed as **DaemonSet** with `hostPort` on worker nodes
- Pre-configured for Proxy Protocol, HSTS, TLS 1.2+, security headers
- Metrics enabled with ServiceMonitor for Prometheus

### cert-manager
- Let's Encrypt email
- ClusterIssuers: staging, production, or both (default: both)
- Domain for cert hostnames
- HTTP-01 solver via nginx ingress class

### Monitoring
- Grafana: admin password (or auto-generated), hostname, TLS issuer, Loki datasource (auto-configured if Logging is also selected)
- Prometheus: retention (default: 30d), storage (default: 50Gi)
- Alertmanager: storage (default: 5Gi)
- Default recording/alerting rules enabled (etcd, apiserver, node)

### Logging
- Loki: SingleBinary mode, filesystem storage, retention (default: 336h / 14 days), storage size (default: 50Gi)
- Promtail: pushes to `http://loki:3100`
- Both deployed to `monitoring` namespace

### Rancher
- Hostname, bootstrap password (or auto-generated), replica count (default: 3)
- Uses Let's Encrypt for TLS via cert-manager

## Output

- Displays pod status across all namespaces
- Prints next steps (Proxy Protocol, ClusterIssuer verification, access URLs)
- Saves credentials to `/root/platform-credentials.txt` (mode 600)

## Critical: Proxy Protocol Ordering

1. Install ingress-nginx first (it expects Proxy Protocol headers)
2. **Then** enable Proxy Protocol on Hetzner LB for ports 80/443
3. **Never** enable Proxy Protocol on port 6443 (breaks kubectl and node joining)

The script pauses to remind you of this after ingress-nginx installation.
