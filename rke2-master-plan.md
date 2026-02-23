# RKE2 Production Cluster — Master Deployment Plan

## Hetzner Cloud | Calico CNI | Ubuntu 24.04

---

## Architecture Overview

```
                          Internet
                             │
                    ┌────────┴────────┐
                    │   Hetzner LB    │
                    │  167.235.216.217│
                    │                 │
                    │ tcp:80  → :80   │  ← Proxy Protocol ON
                    │ tcp:443 → :443  │  ← Proxy Protocol ON
                    │ tcp:6443→ :6443 │  ← Proxy Protocol OFF
                    └────────┬────────┘
                             │ Private Network 10.0.0.0/16
          ┌──────────────────┼──────────────────┐
          │                  │                  │
   ┌──────┴──────┐   ┌──────┴──────┐   ┌──────┴──────┐
   │  server-1   │   │  server-2   │   │  server-3   │
   │  10.0.0.11  │   │  10.0.0.12  │   │  10.0.0.13  │
   │  etcd+cp    │   │  etcd+cp    │   │  etcd+cp    │
   └─────────────┘   └─────────────┘   └─────────────┘
          │                  │                  │
   ┌──────┴──────┐   ┌──────┴──────┐   ┌──────┴──────┐
   │  worker-1   │   │  worker-2   │   │  worker-3   │
   │  10.0.0.21  │   │  10.0.0.22  │   │  10.0.0.23  │
   │  ingress+   │   │  ingress+   │   │  ingress+   │
   │  workloads  │   │  workloads  │   │  workloads  │
   └─────────────┘   └─────────────┘   └─────────────┘
```

**Interfaces per node:**
- `eth0` — public, UFW allows SSH only
- `enp7s0` — private, UFW allows all (trusted VLAN)

**Cluster networking:**
- Pod CIDR: `10.42.0.0/16` (Calico VXLAN)
- Service CIDR: `10.43.0.0/16`
- kube-proxy mode: iptables (RKE2 default)

**Platform services:**
- Ingress: nginx (DaemonSet, hostPort on workers)
- TLS: cert-manager + Let's Encrypt (HTTP-01)
- Monitoring: Prometheus + Grafana + Alertmanager
- Logging: Loki + Promtail
- Management: Rancher
- Storage: local-path-provisioner (node-local disk)

**Data strategy:**
- Application pods are stateless
- Each customer gets their own Postgres pod in their own namespace
- Postgres backups via pg_dump (configured separately)
- No external/cloud storage dependency

---

## Prerequisites

Before starting, you need:

1. **Base image snapshot** — created using `prepare-rke2-node.sh` (already done)
2. **Hetzner Cloud Console access** — to create servers, LB, and networks
3. **DNS access** — A records pointing to the LB public IP (167.235.216.217)
4. **Hetzner private network** — already created, 10.0.0.0/16
5. **Hetzner Load Balancer** — already created at 10.0.0.8 / 167.235.216.217
6. **Your MacBook** — for running kubectl after setup

### DNS Records (create now)

Point these to `167.235.216.217` (your LB public IP):

```
rancher.yourdomain.com    → 167.235.216.217
grafana.yourdomain.com    → 167.235.216.217
*.apps.yourdomain.com     → 167.235.216.217
```

Replace `yourdomain.com` with your actual domain throughout this plan.

---

## Phase 1 — Create Nodes from Snapshot

Create 6 servers from your base image snapshot. All should be attached to the private network.

### Server Nodes (control plane + etcd)

| Hostname | Private IP | Role |
|----------|-----------|------|
| server-1 | 10.0.0.11 | RKE2 server (bootstrap) |
| server-2 | 10.0.0.12 | RKE2 server |
| server-3 | 10.0.0.13 | RKE2 server |

### Worker Nodes

| Hostname | Private IP | Role |
|----------|-----------|------|
| worker-1 | 10.0.0.21 | RKE2 agent |
| worker-2 | 10.0.0.22 | RKE2 agent |
| worker-3 | 10.0.0.23 | RKE2 agent |

### After creating each node

SSH in and set the hostname:

```bash
sudo hostnamectl set-hostname server-1   # or server-2, etc.
```

Verify the private interface is up:

```bash
ip a show enp7s0
# Should show the assigned private IP
```

### Configure Hetzner LB targets

In Hetzner Console → Load Balancers → your LB → Targets:

Add all 6 nodes as targets (use their private IPs). The LB needs to reach:
- Servers on port 6443 (Kubernetes API)
- Workers on ports 80 and 443 (web traffic)

**LB Health Check** — configure for port 6443:
- Protocol: TCP
- Interval: 15s
- Timeout: 10s
- Retries: 3

---

## Phase 2 — Bootstrap server-1

SSH into server-1.

### Create RKE2 config

```bash
sudo mkdir -p /etc/rancher/rke2
```

```bash
sudo tee /etc/rancher/rke2/config.yaml <<'EOF'
# server-1 — bootstrap node (first server)
token: "YOUR_SECURE_TOKEN_HERE"

# Bind everything to private interface
node-ip: "10.0.0.11"
bind-address: "10.0.0.11"
advertise-address: "10.0.0.11"

# TLS SANs — all ways the API server might be reached
tls-san:
  - "10.0.0.8"
  - "167.235.216.217"
  - "10.0.0.11"
  - "server-1"

# CNI
cni: calico

# Kubelet
kubelet-arg:
  - "node-ip=10.0.0.11"

# Metrics
etcd-expose-metrics: true

# Audit logging
kube-apiserver-arg:
  - "audit-log-path=/var/lib/rancher/rke2/server/logs/audit.log"
  - "audit-log-maxage=30"
  - "audit-log-maxbackup=10"
  - "audit-log-maxsize=100"
EOF
```

**Generate a secure token** (run on your MacBook or any machine):

```bash
openssl rand -hex 32
```

Replace `YOUR_SECURE_TOKEN_HERE` with the output. Use this same token on all nodes.

### Install and start RKE2

```bash
curl -sfL https://get.rke2.io | sudo sh -
sudo systemctl enable rke2-server
sudo systemctl start rke2-server
```

### Wait for it to come up

```bash
# Watch the startup (takes 2-5 minutes)
sudo journalctl -u rke2-server -f
```

Wait until you see messages about the node being ready.

### Set up kubectl on server-1

```bash
echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin' >> ~/.bashrc
echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> ~/.bashrc
source ~/.bashrc

sudo chmod 644 /etc/rancher/rke2/rke2.yaml
```

### Verify

```bash
kubectl get nodes
# NAME       STATUS   ROLES                       AGE   VERSION
# server-1   Ready    control-plane,etcd,master   Xm    vX.XX.X+rke2rX
```

```bash
kubectl get pods -A
# All pods should be Running or Completed
```

---

## Phase 3 — Join server-2 and server-3

**Join one at a time. Wait for each to be Ready before starting the next.** etcd quorum requires careful sequencing.

### server-2

SSH into server-2:

```bash
sudo mkdir -p /etc/rancher/rke2
```

```bash
sudo tee /etc/rancher/rke2/config.yaml <<'EOF'
# server-2 — joins via LB
token: "YOUR_SECURE_TOKEN_HERE"
server: "https://10.0.0.8:6443"

node-ip: "10.0.0.12"
bind-address: "10.0.0.12"
advertise-address: "10.0.0.12"

tls-san:
  - "10.0.0.8"
  - "167.235.216.217"
  - "10.0.0.12"
  - "server-2"

cni: calico

kubelet-arg:
  - "node-ip=10.0.0.12"

etcd-expose-metrics: true

kube-apiserver-arg:
  - "audit-log-path=/var/lib/rancher/rke2/server/logs/audit.log"
  - "audit-log-maxage=30"
  - "audit-log-maxbackup=10"
  - "audit-log-maxsize=100"
EOF
```

```bash
curl -sfL https://get.rke2.io | sudo sh -
sudo systemctl enable rke2-server
sudo systemctl start rke2-server
```

**Wait on server-1:**

```bash
kubectl get nodes
# Wait until server-2 shows Ready
```

### server-3

SSH into server-3 — same process, change `node-ip`, `advertise-address`, `tls-san` to `10.0.0.13` / `server-3`:

```bash
sudo mkdir -p /etc/rancher/rke2
```

```bash
sudo tee /etc/rancher/rke2/config.yaml <<'EOF'
token: "YOUR_SECURE_TOKEN_HERE"
server: "https://10.0.0.8:6443"

node-ip: "10.0.0.13"
bind-address: "10.0.0.13"
advertise-address: "10.0.0.13"

tls-san:
  - "10.0.0.8"
  - "167.235.216.217"
  - "10.0.0.13"
  - "server-3"

cni: calico

kubelet-arg:
  - "node-ip=10.0.0.13"

etcd-expose-metrics: true

kube-apiserver-arg:
  - "audit-log-path=/var/lib/rancher/rke2/server/logs/audit.log"
  - "audit-log-maxage=30"
  - "audit-log-maxbackup=10"
  - "audit-log-maxsize=100"
EOF
```

```bash
curl -sfL https://get.rke2.io | sudo sh -
sudo systemctl enable rke2-server
sudo systemctl start rke2-server
```

**Verify on server-1:**

```bash
kubectl get nodes
# All 3 servers should be Ready

# Verify etcd health
sudo /var/lib/rancher/rke2/bin/etcdctl \
  --cacert /var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  --cert /var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
  --key /var/lib/rancher/rke2/server/tls/etcd/server-client.key \
  endpoint status --cluster -w table
```

---

## Phase 4 — Join Workers

Workers can join in parallel (they don't run etcd).

### For each worker (worker-1, worker-2, worker-3)

SSH into the worker. Adjust `node-ip` and hostname for each:

**worker-1 (10.0.0.21):**

```bash
sudo mkdir -p /etc/rancher/rke2
```

```bash
sudo tee /etc/rancher/rke2/config.yaml <<'EOF'
token: "YOUR_SECURE_TOKEN_HERE"
server: "https://10.0.0.8:6443"

node-ip: "10.0.0.21"

kubelet-arg:
  - "node-ip=10.0.0.21"
EOF
```

```bash
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sudo sh -
sudo systemctl enable rke2-agent
sudo systemctl start rke2-agent
```

**worker-2 (10.0.0.22):** Same but `node-ip: "10.0.0.22"` and `kubelet-arg: "node-ip=10.0.0.22"`.

**worker-3 (10.0.0.23):** Same but `node-ip: "10.0.0.23"` and `kubelet-arg: "node-ip=10.0.0.23"`.

### Label workers

On server-1:

```bash
kubectl label node worker-1 node-role.kubernetes.io/worker=worker
kubectl label node worker-2 node-role.kubernetes.io/worker=worker
kubectl label node worker-3 node-role.kubernetes.io/worker=worker
```

### Verify

```bash
kubectl get nodes
# NAME       STATUS   ROLES                       AGE   VERSION
# server-1   Ready    control-plane,etcd,master   Xm    vX.XX.X
# server-2   Ready    control-plane,etcd,master   Xm    vX.XX.X
# server-3   Ready    control-plane,etcd,master   Xm    vX.XX.X
# worker-1   Ready    worker                      Xm    vX.XX.X
# worker-2   Ready    worker                      Xm    vX.XX.X
# worker-3   Ready    worker                      Xm    vX.XX.X
```

---

## Phase 5 — Helm

On server-1:

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Verify:

```bash
helm version
```

---

## Phase 6 — Local Storage Provisioner

Prometheus, Grafana, Loki, and Alertmanager all need PersistentVolumeClaims. Without a StorageClass, those pods get stuck in Pending.

```bash
kubectl apply -f \
  https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
```

Set as default StorageClass:

```bash
kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

Verify:

```bash
kubectl get storageclass
# NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      AGE
# local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   Xs
```

**Note:** local-path provisions directories on the node where the pod runs. Data survives pod restarts but is tied to the specific node. If a node dies, that data is lost. This is acceptable because our application data lives in Postgres (backed up separately via pg_dump) and monitoring data is operational, not critical.

---

## Phase 7 — Ingress-Nginx with Proxy Protocol

This is a two-step process. **Order matters** — nginx must be configured to expect Proxy Protocol headers before you enable Proxy Protocol on the LB. Otherwise every request gets a 400 Bad Request.

### Step 1: Install ingress-nginx

```bash
cat <<'EOF' > /tmp/ingress-nginx-values.yaml
controller:
  kind: DaemonSet

  hostPort:
    enabled: true

  service:
    enabled: false

  nodeSelector:
    node-role.kubernetes.io/worker: "worker"

  config:
    # Proxy Protocol — parse real client IP from Hetzner LB header
    use-proxy-protocol: "true"
    use-forwarded-headers: "true"
    compute-full-forwarded-for: "true"

    # Only trust the LB as a proxy source — prevents IP spoofing
    proxy-real-ip-cidr: "10.0.0.8/32"

    # Security headers
    hide-headers: "Server,X-Powered-By"
    hsts: "true"
    hsts-max-age: "31536000"
    hsts-include-subdomains: "true"

    # Limits
    proxy-body-size: "50m"
    proxy-read-timeout: "120"
    proxy-send-timeout: "120"

    # TLS
    ssl-protocols: "TLSv1.2 TLSv1.3"
    ssl-prefer-server-ciphers: "true"

    # Access logs with real client IPs
    log-format-upstream: >-
      $remote_addr - $remote_user [$time_local] "$request"
      $status $body_bytes_sent "$http_referer" "$http_user_agent"
      $request_length $request_time
      [$proxy_upstream_name] $upstream_addr
      $upstream_response_length $upstream_response_time $upstream_status $req_id

  admissionWebhooks:
    enabled: true

  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      namespace: monitoring

  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      memory: 256Mi
EOF
```

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  -f /tmp/ingress-nginx-values.yaml
```

Wait for pods:

```bash
kubectl get pods -n ingress-nginx -w
# Wait until all DaemonSet pods are Running (one per worker)
```

### Step 2: Enable Proxy Protocol on Hetzner LB

**Only do this AFTER nginx pods are Running.**

In Hetzner Console → Load Balancers → your LB → Services:

| Service | Proxy Protocol |
|---------|---------------|
| tcp:80 → 80 | **ENABLE** |
| tcp:443 → 443 | **ENABLE** |
| tcp:6443 → 6443 | **DO NOT ENABLE** |

Enabling Proxy Protocol on 6443 will break kubectl and node joining — the API server does not speak Proxy Protocol.

### Step 3: Verify real client IPs

From your MacBook:

```bash
curl -I http://167.235.216.217
```

Check nginx logs on server-1:

```bash
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=5
```

You should see your real public IP address in the logs, not `10.0.0.8`.

---

## Phase 8 — cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi
```

Wait for ready:

```bash
kubectl get pods -n cert-manager -w
```

### Create ClusterIssuers

**Staging first** (no rate limits, untrusted cert — for testing):

```bash
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: your-email@yourdomain.com
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
```

**Production** (real trusted cert — rate-limited):

```bash
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@yourdomain.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
```

Verify:

```bash
kubectl get clusterissuer
# Both should show READY=True after a few seconds
```

---

## Phase 9 — Monitoring (Prometheus + Grafana + Alertmanager)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

```bash
cat <<'EOF' > /tmp/monitoring-values.yaml
# Prometheus
prometheus:
  prometheusSpec:
    retention: 30d
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        memory: 2Gi

# Alertmanager
alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 5Gi
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        memory: 128Mi

# Grafana
grafana:
  adminPassword: "CHANGE_ME_TO_SOMETHING_SECURE"
  persistence:
    enabled: true
    size: 10Gi
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      cert-manager.io/cluster-issuer: "letsencrypt-staging"
    hosts:
      - grafana.yourdomain.com
    tls:
      - secretName: grafana-tls
        hosts:
          - grafana.yourdomain.com
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      memory: 256Mi
  additionalDataSources:
    - name: Loki
      type: loki
      url: http://loki:3100
      access: proxy
      isDefault: false

# Node Exporter — runs on every node
nodeExporter:
  resources:
    requests:
      cpu: 50m
      memory: 32Mi
    limits:
      memory: 64Mi

# Kube State Metrics
kubeStateMetrics:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      memory: 128Mi

# Pre-built dashboards
defaultRules:
  create: true
  rules:
    etcd: true
    kubeApiserver: true
    kubePrometheusNodeRecording: true
EOF
```

```bash
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  -f /tmp/monitoring-values.yaml
```

Verify:

```bash
kubectl get pods -n monitoring -w
# Wait for all pods to be Running

# Check Prometheus targets
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090 &
# Visit http://localhost:9090/targets — all targets should be UP
```

---

## Phase 10 — Loki (Centralized Logging)

Loki collects logs from every pod via Promtail (DaemonSet). Grafana queries Loki just like it queries Prometheus — metrics and logs in one place.

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

### Install Loki

```bash
cat <<'EOF' > /tmp/loki-values.yaml
loki:
  deploymentMode: SingleBinary

  singleBinary:
    replicas: 1
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        memory: 1Gi

  # Local storage
  storage:
    type: filesystem

  # Keep 14 days of logs
  limits_config:
    retention_period: 336h

  compactor:
    retention_enabled: true

  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: index_
          period: 24h

  persistence:
    enabled: true
    size: 50Gi

  gateway:
    enabled: false

# Disable bundled promtail (we install separately for more control)
promtail:
  enabled: false
EOF
```

```bash
helm install loki grafana/loki \
  --namespace monitoring \
  -f /tmp/loki-values.yaml
```

### Install Promtail

Promtail runs on every node, tails `/var/log/pods/*`, and ships logs to Loki.

```bash
helm install promtail grafana/promtail \
  --namespace monitoring \
  --set "config.clients[0].url=http://loki:3100/loki/api/v1/push"
```

Verify:

```bash
# Promtail should have one pod per node (DaemonSet)
kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail

# Loki should be Running
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki
```

### Test in Grafana

Once Grafana is accessible, go to Explore → select "Loki" datasource → query:

```logql
{namespace="monitoring"}
```

You should see logs from monitoring pods. Useful queries for later:

```logql
# All logs from a customer namespace
{namespace="customer-a"}

# Errors only
{namespace="customer-a"} |= "error"

# Postgres slow queries
{namespace="customer-a", container="postgres"} |= "duration"

# JSON structured logs
{namespace="customer-a"} | json | level="error"
```

---

## Phase 11 — Rancher

```bash
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo update
```

```bash
helm install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --create-namespace \
  --set hostname=rancher.yourdomain.com \
  --set ingress.tls.source=letsEncrypt \
  --set letsEncrypt.email=your-email@yourdomain.com \
  --set letsEncrypt.ingress.class=nginx \
  --set replicas=3 \
  --set bootstrapPassword="CHANGE_ME_BOOTSTRAP_PASSWORD" \
  --set resources.requests.cpu=250m \
  --set resources.requests.memory=256Mi \
  --set resources.limits.memory=1Gi
```

Wait for rollout:

```bash
kubectl rollout status deployment/rancher -n cattle-system -w
```

Access Rancher at `https://rancher.yourdomain.com` and:
1. Log in with the bootstrap password
2. Set a real admin password
3. Set the Rancher Server URL to `https://rancher.yourdomain.com`

---

## Phase 12 — Network Policies (Namespace Isolation)

Every customer namespace gets default-deny plus targeted allows. This prevents any pod from reaching pods in other namespaces, system services, or the cluster infrastructure.

### Base policy template

Save this as a file. Apply it to every customer namespace by replacing `NAMESPACE`:

```bash
cat <<'EOF' > /tmp/namespace-network-policies.yaml
# 1. Default deny all traffic
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress

---
# 2. Allow DNS (pods need to resolve hostnames)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53

---
# 3. Allow inbound from ingress-nginx (web traffic reaches pods)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-ingress
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx

---
# 4. Allow intra-namespace traffic (app pods talk to their own postgres)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector: {}
  egress:
    - to:
        - podSelector: {}

---
# 5. Allow Prometheus scraping from monitoring namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scrape
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 9090
        - protocol: TCP
          port: 8080
        - protocol: TCP
          port: 3000
EOF
```

### Apply to a customer namespace

```bash
kubectl create namespace customer-a
kubectl apply -f /tmp/namespace-network-policies.yaml -n customer-a
```

### What this gives each customer namespace

- ❌ Cannot reach other customer namespaces
- ❌ Cannot reach Rancher, Grafana, or system services
- ❌ Cannot reach the internet from pods (unless you add the egress policy below)
- ✅ Receives web traffic from nginx ingress
- ✅ App pods talk to their own Postgres pod
- ✅ Can resolve DNS
- ✅ Prometheus can scrape metrics

### Optional: Allow internet egress

If a customer's app needs to call external APIs, add this to their namespace:

```bash
cat <<'EOF' > /tmp/allow-internet-egress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-internet
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8       # Private network
              - 10.42.0.0/16     # Pod CIDR
              - 10.43.0.0/16     # Service CIDR
      ports:
        - protocol: TCP
          port: 443
        - protocol: TCP
          port: 80
EOF
```

```bash
kubectl apply -f /tmp/allow-internet-egress.yaml -n customer-a
```

This allows HTTPS/HTTP to the internet but blocks access to all internal cluster networks — a compromised pod cannot reach other pods, services, or nodes even with internet egress.

---

## Phase 13 — Switch to Production Certificates

Once everything works with staging certs:

### Update Grafana

```bash
cat <<'EOF' > /tmp/monitoring-cert-patch.yaml
grafana:
  ingress:
    annotations:
      cert-manager.io/cluster-issuer: "letsencrypt-prod"
    tls:
      - secretName: grafana-tls-prod
        hosts:
          - grafana.yourdomain.com
EOF
```

```bash
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f /tmp/monitoring-values.yaml \
  -f /tmp/monitoring-cert-patch.yaml
```

Delete the old staging secret so cert-manager provisions a new one:

```bash
kubectl delete secret grafana-tls -n monitoring
```

### Update Rancher

Rancher manages its own cert-manager integration. If you used `letsEncrypt` as the TLS source, it already uses the production Let's Encrypt endpoint by default. Verify:

```bash
kubectl get certificate -n cattle-system
# Should show READY=True
```

### Verify certificates

```bash
# Check Grafana cert
echo | openssl s_client -connect grafana.yourdomain.com:443 -servername grafana.yourdomain.com 2>/dev/null | openssl x509 -noout -issuer -dates

# Should show issuer: Let's Encrypt (not Fake LE Intermediate)
```

---

## Phase 14 — End-to-End Test

Deploy a test app to verify the entire chain works.

```bash
kubectl create namespace test-app
kubectl apply -f /tmp/namespace-network-policies.yaml -n test-app
```

```bash
kubectl apply -n test-app -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-nginx
spec:
  replicas: 2
  selector:
    matchLabels:
      app: test-nginx
  template:
    metadata:
      labels:
        app: test-nginx
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: test-nginx
spec:
  selector:
    app: test-nginx
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: test-nginx
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - test.apps.yourdomain.com
      secretName: test-nginx-tls
  rules:
    - host: test.apps.yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: test-nginx
                port:
                  number: 80
EOF
```

Verify:

```bash
# Wait for cert
kubectl get certificate -n test-app -w
# Wait for READY=True

# Test from your MacBook
curl -I https://test.apps.yourdomain.com
# Should return 200 with valid TLS

# Check nginx logs show your real IP (not 10.0.0.8)
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=5
```

Clean up:

```bash
kubectl delete namespace test-app
```

---

## Phase 15 — Local kubectl (MacBook)

Copy the kubeconfig from server-1 to your Mac:

```bash
# On your MacBook
mkdir -p ~/.kube
scp your-user@SERVER_1_PUBLIC_IP:/etc/rancher/rke2/rke2.yaml ~/.kube/rke2-config
```

Edit the file — change the server URL to the LB:

```bash
sed -i '' 's|https://127.0.0.1:6443|https://167.235.216.217:6443|' ~/.kube/rke2-config
```

Use it:

```bash
export KUBECONFIG=~/.kube/rke2-config
kubectl get nodes
```

Or merge with your existing kubeconfig if you have one.

---

## Network Flow Reference

### Inbound Web Traffic

```
Client browser
  → DNS (app.yourdomain.com → 167.235.216.217)
  → Hetzner LB:443 (TCP + Proxy Protocol header with real client IP)
  → Worker enp7s0:443 (UFW allows all on enp7s0)
  → ingress-nginx hostPort (parses Proxy Protocol, extracts real IP)
  → TLS termination (cert from cert-manager Secret)
  → Host header match → Ingress rule
  → Service ClusterIP → kube-proxy iptables DNAT → Pod IP
  → Calico VXLAN (if cross-node) → Pod receives plain HTTP
```

### Let's Encrypt Certificate Flow

```
Ingress created with cert-manager annotation
  → cert-manager creates Certificate resource
  → Temporary Ingress + pod for HTTP-01 challenge
  → Let's Encrypt verifies: Internet → LB:80 → worker → nginx → challenge pod
  → cert-manager stores cert as Secret
  → nginx picks up Secret, serves TLS
```

### kubectl from MacBook

```
kubectl → https://167.235.216.217:6443
  → Hetzner LB:6443 (TCP passthrough, NO Proxy Protocol)
  → Server enp7s0:6443 → kube-apiserver
  → Client cert auth + RBAC → Response
```

### Pod-to-Pod (cross-node)

```
Pod A (worker-1) → Calico VXLAN interface
  → UDP:4789 encapsulated: src=10.0.0.21 dst=10.0.0.22
  → enp7s0 → Physical network → worker-2 enp7s0
  → VXLAN decapsulation → Calico routes → Pod B
```

### Logging flow

```
Pod stdout/stderr → containerd → /var/log/pods/*
  → Promtail (DaemonSet on every node) tails log files
  → Ships to Loki with labels (namespace, pod, container)
  → Grafana queries Loki via LogQL
```

---

## Deploying a Customer App (Template)

When onboarding a new customer, follow this pattern:

### 1. Create namespace + policies

```bash
CUSTOMER="customer-name"

kubectl create namespace "$CUSTOMER"
kubectl apply -f /tmp/namespace-network-policies.yaml -n "$CUSTOMER"

# If the app needs internet egress:
kubectl apply -f /tmp/allow-internet-egress.yaml -n "$CUSTOMER"
```

### 2. Deploy Postgres

```bash
kubectl apply -n "$CUSTOMER" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: "appdb"
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: password
          volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/postgresql/data
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 512Mi
      volumes:
        - name: postgres-data
          persistentVolumeClaim:
            claimName: postgres-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 20Gi
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
EOF
```

Create the secret first:

```bash
kubectl create secret generic postgres-credentials \
  -n "$CUSTOMER" \
  --from-literal=username=appuser \
  --from-literal=password="$(openssl rand -base64 24)"
```

### 3. Deploy the application + Ingress

```bash
kubectl apply -n "$CUSTOMER" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: customer-app
  template:
    metadata:
      labels:
        app: customer-app
    spec:
      containers:
        - name: app
          image: your-registry/customer-app:latest
          ports:
            - containerPort: 3000
          env:
            - name: DATABASE_URL
              value: "postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@postgres:5432/appdb"
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: app
spec:
  selector:
    app: customer-app
  ports:
    - port: 80
      targetPort: 3000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - customer-name.apps.yourdomain.com
      secretName: customer-app-tls
  rules:
    - host: customer-name.apps.yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app
                port:
                  number: 80
EOF
```

### 4. Set up pg_dump backup (configure separately per customer)

This will be a CronJob in the customer namespace that dumps to a backup destination. To be configured as a separate task.

---

## Pre-Production Checklist

### Cluster Health
- [ ] All 6 nodes Ready with correct roles
- [ ] All system pods Running (`kubectl get pods -A`)
- [ ] etcd cluster healthy (3 members)

### Storage
- [ ] local-path StorageClass is default
- [ ] Prometheus, Grafana, Loki PVCs are Bound

### Networking
- [ ] Proxy Protocol enabled on LB (ports 80/443 only, NOT 6443)
- [ ] nginx logs show real client IPs (not 10.0.0.8)
- [ ] LB health checks green for all targets
- [ ] kubectl works from MacBook via LB:6443

### Security
- [ ] UFW: SSH on eth0 only, allow-all on enp7s0
- [ ] SSH hardened (no root, no password, max 3 retries)
- [ ] Fail2ban active on all nodes
- [ ] Auditd active on all nodes
- [ ] Default-deny NetworkPolicies on customer namespaces
- [ ] Audit logging enabled on kube-apiserver

### Certificates
- [ ] cert-manager running
- [ ] ClusterIssuers READY (staging + production)
- [ ] Production certs issued and valid

### Monitoring
- [ ] Prometheus scraping all targets
- [ ] Grafana accessible with dashboards
- [ ] Alertmanager running
- [ ] node-exporter on all 6 nodes

### Logging
- [ ] Loki running and receiving logs
- [ ] Promtail DaemonSet on all nodes
- [ ] Logs queryable in Grafana Explore

### Management
- [ ] Rancher accessible
- [ ] Admin password set (not bootstrap)
- [ ] Server URL configured

---

## Monitoring Stack Overview

```
                    ┌──────────────────────────────────┐
                    │            Grafana                │
                    │   Dashboards / Explore / Alerts   │
                    └────────┬───────────┬──────────────┘
                             │           │
                    ┌────────┴────┐ ┌────┴─────────┐
                    │ Prometheus  │ │     Loki     │
                    │  (metrics)  │ │    (logs)    │
                    └──────┬──────┘ └──────┬───────┘
                           │               │
              ┌────────────┼────────┐      │
              │            │        │      │
         node-exporter  kube-    app    Promtail
         (host metrics) state  metrics (DaemonSet,
                        metrics         tails pod logs
                                        on every node)
```

Prometheus tells you "this pod is using 95% memory."
Loki tells you "here are the log lines showing what it was doing."
Together in Grafana, you get the full picture.

---

## Quick Reference — Useful Commands

```bash
# Cluster status
kubectl get nodes -o wide
kubectl get pods -A

# Check a specific customer
kubectl get pods -n customer-a
kubectl logs -n customer-a deployment/app
kubectl logs -n customer-a deployment/postgres

# Ingress status
kubectl get ingress -A
kubectl get certificate -A

# Storage
kubectl get pvc -A

# Network policies
kubectl get networkpolicy -n customer-a

# Monitoring
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80

# Loki logs via CLI
kubectl logs -n monitoring -l app.kubernetes.io/name=loki

# etcd health
sudo /var/lib/rancher/rke2/bin/etcdctl \
  --cacert /var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  --cert /var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
  --key /var/lib/rancher/rke2/server/tls/etcd/server-client.key \
  endpoint status --cluster -w table

# Restart a service
kubectl rollout restart deployment/app -n customer-a
```
