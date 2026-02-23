# Correctness & Bug Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix 10 correctness issues and align convention violations across the VPS deployment scripts.

**Architecture:** Targeted edits to `lib.sh`, `init.1.vps.sh`, `init.2.rke2.sh`, and `init.3.pods.sh`. No new files except the plan doc itself. Each task is one logical fix, validated with `bash -n` and `shellcheck -x`.

**Tech Stack:** Bash, shellcheck, Ubuntu 24.04 server target

**Validation command (run after every code change):**
```bash
bash -n lib.sh && bash -n init.1.vps.sh && bash -n init.2.rke2.sh && bash -n init.3.pods.sh && shellcheck -x lib.sh init.1.vps.sh init.2.rke2.sh init.3.pods.sh
```

---

### Task 1: Add `detect_public_iface()` to lib.sh

**Files:**
- Modify: `lib.sh` (after `detect_private_iface()`, around line 271)

**Step 1: Add the function**

Insert after `detect_private_iface()`:

```bash
# detect_public_iface — sets PUBLIC_IFACE to the default-route interface
detect_public_iface() {
    PUBLIC_IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    [[ -n "$PUBLIC_IFACE" ]]
}
```

**Step 2: Validate**

Run: `bash -n lib.sh && shellcheck -x lib.sh`
Expected: Clean (SC2034 warnings for exported globals are pre-existing and OK)

**Step 3: Commit**

```bash
git add lib.sh
git commit -m "lib: add detect_public_iface() for default-route interface"
```

---

### Task 2: Fix hardcoded `eth0` in UFW rules (init.1.vps.sh)

**Files:**
- Modify: `init.1.vps.sh:293-297`

**Step 1: Replace the K8s UFW block**

Find (around line 293-297):
```bash
    # K8s: SSH on public interface only, allow all on private
    ufw allow in on eth0 to any port "${SSH_PORT}" proto tcp comment 'SSH'
    ufw allow in on "${PRIVATE_IFACE}" comment 'Private network'
    log "UFW: eth0=SSH only, ${PRIVATE_IFACE}=all traffic"
```

Replace with:
```bash
    # K8s: SSH on public interface only, allow all on private
    detect_public_iface || { err "Cannot detect public interface for UFW rules"; exit 1; }
    ufw allow in on "${PUBLIC_IFACE}" to any port "${SSH_PORT}" proto tcp comment 'SSH'
    ufw allow in on "${PRIVATE_IFACE}" comment 'Private network'
    log "UFW: ${PUBLIC_IFACE}=SSH only, ${PRIVATE_IFACE}=all traffic"
```

**Step 2: Validate**

Run: `bash -n init.1.vps.sh && shellcheck -x init.1.vps.sh`

**Step 3: Commit**

```bash
git add init.1.vps.sh
git commit -m "vps: detect public interface instead of hardcoding eth0"
```

---

### Task 3: Remove ineffective /run/shm fstab append (init.1.vps.sh)

**Files:**
- Modify: `init.1.vps.sh:457-459`

**Step 1: Delete the shared memory block**

Remove these lines (around 457-459):
```bash
    # Secure shared memory
    if ! grep -q "tmpfs /run/shm" /etc/fstab; then
        echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid 0 0" >> /etc/fstab
    fi
```

**Step 2: Validate**

Run: `bash -n init.1.vps.sh && shellcheck -x init.1.vps.sh`

**Step 3: Commit**

```bash
git add init.1.vps.sh
git commit -m "vps: remove ineffective /run/shm fstab append (symlink on Ubuntu 24.04)"
```

---

### Task 4: Fix leading space on PermitRootLogin (init.1.vps.sh)

**Files:**
- Modify: `init.1.vps.sh:240`

**Step 1: Remove the leading space**

In the SSH config heredoc (around line 240), change:
```
 PermitRootLogin no
```
to:
```
PermitRootLogin no
```

(Remove exactly one leading space character.)

**Step 2: Validate**

Run: `bash -n init.1.vps.sh && shellcheck -x init.1.vps.sh`

**Step 3: Commit**

```bash
git add init.1.vps.sh
git commit -m "vps: fix leading space in PermitRootLogin SSH config"
```

---

### Task 5: Add SSH lockout safety check (init.1.vps.sh)

**Files:**
- Modify: `init.1.vps.sh` (between SSH public key collection at ~line 74 and private interface detection at ~line 77)

**Step 1: Add safety check after user creation decision**

Insert after the `fi` that closes the "Create a non-root sudo user?" block (line 74), before the private interface section (line 77):

```bash
# Safety: warn if no SSH user will exist after PermitRootLogin=no
if [[ "$CREATE_USER" != "y" ]]; then
    HAS_SSH_USER="n"
    for hdir in /home/*/; do
        [ -d "$hdir" ] || continue
        local_user=$(basename "$hdir")
        if [[ -f "${hdir}.ssh/authorized_keys" ]] && id "$local_user" &>/dev/null; then
            HAS_SSH_USER="y"
            break
        fi
    done

    if [[ "$HAS_SSH_USER" != "y" ]]; then
        echo ""
        warn "═══════════════════════════════════════════════════════════════"
        warn "  No non-root user with SSH keys found on this system!"
        warn "  PermitRootLogin=no will LOCK YOU OUT."
        warn "═══════════════════════════════════════════════════════════════"
        echo ""
        if ! ask_yesno "Continue WITHOUT a non-root SSH user? (DANGEROUS)" "n"; then
            info "Aborted. Re-run and create a user."
            exit 0
        fi
    fi
fi
```

**Step 2: Validate**

Run: `bash -n init.1.vps.sh && shellcheck -x init.1.vps.sh`

**Step 3: Commit**

```bash
git add init.1.vps.sh
git commit -m "vps: add SSH lockout safety check when no user is created"
```

---

### Task 6: Fix backgrounded systemctl start (init.2.rke2.sh)

**Files:**
- Modify: `init.2.rke2.sh:385-419` (the "Enable + start" and "Wait for ready" sections)

**Step 1: Replace backgrounded start + wait loop**

Replace the entire block from `separator "Starting RKE2"` through the timeout check (lines 385-419) with:

```bash
separator "Starting RKE2"

if [[ "$NODE_ROLE" -eq 3 ]]; then
    RKE2_SERVICE="rke2-agent"
else
    RKE2_SERVICE="rke2-server"
fi

systemctl enable "$RKE2_SERVICE"
info "Starting ${RKE2_SERVICE}... (this may take several minutes)"

if ! timeout 300 systemctl start "$RKE2_SERVICE"; then
    err "${RKE2_SERVICE} failed to start within 300s"
    err "Check: journalctl -u ${RKE2_SERVICE} --no-pager -n 50"
    exit 1
fi

log "${RKE2_SERVICE} started"
```

Also keep the "Extra wait for server nodes" block that follows (lines 421-425):
```bash
# Extra wait for server nodes to settle
if [[ "$NODE_ROLE" -le 2 ]]; then
    info "Waiting 30s for API server to settle..."
    sleep 30
fi
```

**Step 2: Validate**

Run: `bash -n init.2.rke2.sh && shellcheck -x init.2.rke2.sh`

**Step 3: Commit**

```bash
git add init.2.rke2.sh
git commit -m "rke2: replace backgrounded systemctl start with timeout"
```

---

### Task 7: Fix KUBECONFIG permissions (init.2.rke2.sh)

**Files:**
- Modify: `init.2.rke2.sh:443`

**Step 1: Change permission**

Change:
```bash
    chmod 644 /etc/rancher/rke2/rke2.yaml
```
to:
```bash
    chmod 600 /etc/rancher/rke2/rke2.yaml
```

**Step 2: Validate**

Run: `bash -n init.2.rke2.sh && shellcheck -x init.2.rke2.sh`

**Step 3: Commit**

```bash
git add init.2.rke2.sh
git commit -m "rke2: restrict KUBECONFIG to 600 (was world-readable 644)"
```

---

### Task 8: Replace .bashrc appends with /etc/profile.d (init.2.rke2.sh)

**Files:**
- Modify: `init.2.rke2.sh:431-439`

**Step 1: Replace .bashrc mutation with profile.d overwrite**

Replace lines 431-439 (the BASHRC block including the grep guards) with:

```bash
    # Set up kubectl for all users via profile.d (idempotent overwrite)
    cat > /etc/profile.d/rke2.sh <<'PROFILEEOF'
export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
PROFILEEOF
```

Keep the two `export` lines that follow for the current shell session:
```bash
    export PATH=$PATH:/var/lib/rancher/rke2/bin
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
```

**Step 2: Validate**

Run: `bash -n init.2.rke2.sh && shellcheck -x init.2.rke2.sh`

**Step 3: Commit**

```bash
git add init.2.rke2.sh
git commit -m "rke2: use /etc/profile.d instead of .bashrc appends (convention)"
```

---

### Task 9: Add CNI mismatch warning for joining servers (init.2.rke2.sh)

**Files:**
- Modify: `init.2.rke2.sh:133` (before the CNI choice for joining servers)

**Step 1: Add warning**

Before `ask_choice "CNI (must match bootstrap node)?"` (around line 135), insert:

```bash
    echo ""
    warn "CNI MUST match the bootstrap node. A mismatch causes silent join failures."
```

**Step 2: Validate**

Run: `bash -n init.2.rke2.sh && shellcheck -x init.2.rke2.sh`

**Step 3: Commit**

```bash
git add init.2.rke2.sh
git commit -m "rke2: add prominent CNI mismatch warning for joining servers"
```

---

### Task 10: Secure temp files and Rancher password (init.3.pods.sh)

**Files:**
- Modify: `init.3.pods.sh` (multiple locations)

**Step 1: Add secure tmpdir + cleanup trap**

After the `set -euo pipefail` and `source` lines (around line 13), add:

```bash
TMPDIR_PODS=$(mktemp -d)
chmod 700 "$TMPDIR_PODS"
trap 'rm -rf "$TMPDIR_PODS"' EXIT
```

**Step 2: Replace all `/tmp/` paths**

Replace every occurrence:
- `/tmp/ingress-nginx-values.yaml` -> `"${TMPDIR_PODS}/ingress-nginx-values.yaml"`
- `/tmp/monitoring-values.yaml` -> `"${TMPDIR_PODS}/monitoring-values.yaml"`
- `/tmp/loki-values.yaml` -> `"${TMPDIR_PODS}/loki-values.yaml"`

There are 3 `cat >` writes and 3 `helm ... -f` references, for a total of 6 replacements.

**Step 3: Move Rancher password to values file**

In the Rancher helm install section (around line 570), change:
```bash
    helm upgrade --install rancher rancher-stable/rancher \
        --namespace cattle-system \
        --create-namespace \
        --set hostname="${RANCHER_HOST}" \
        --set ingress.tls.source=letsEncrypt \
        --set "letsEncrypt.email=${CERT_EMAIL}" \
        --set letsEncrypt.ingress.class=nginx \
        --set "replicas=${RANCHER_REPLICAS}" \
        --set "bootstrapPassword=${RANCHER_PASSWORD}" \
        --set resources.requests.cpu=250m \
        --set resources.requests.memory=256Mi \
        --set resources.limits.memory=1Gi
```

to:
```bash
    cat > "${TMPDIR_PODS}/rancher-values.yaml" <<EOF
hostname: "${RANCHER_HOST}"
ingress:
  tls:
    source: letsEncrypt
letsEncrypt:
  email: "${CERT_EMAIL}"
  ingress:
    class: nginx
replicas: ${RANCHER_REPLICAS}
bootstrapPassword: "${RANCHER_PASSWORD}"
resources:
  requests:
    cpu: 250m
    memory: 256Mi
  limits:
    memory: 1Gi
EOF

    helm upgrade --install rancher rancher-stable/rancher \
        --namespace cattle-system \
        --create-namespace \
        -f "${TMPDIR_PODS}/rancher-values.yaml"
```

**Step 4: Validate**

Run: `bash -n init.3.pods.sh && shellcheck -x init.3.pods.sh`

**Step 5: Commit**

```bash
git add init.3.pods.sh
git commit -m "pods: secure temp files with mktemp + trap, move rancher password off CLI"
```

---

### Task 11: Extract local-path-provisioner version (init.3.pods.sh)

**Files:**
- Modify: `init.3.pods.sh` (top of file + line 253)

**Step 1: Add version variable**

Near the top of the script, after the `source` line, add:

```bash
LOCAL_PATH_VERSION="v0.0.30"
```

**Step 2: Use the variable in the kubectl apply**

Change:
```bash
    kubectl apply -f \
        https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
```
to:
```bash
    kubectl apply -f \
        "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
```

**Step 3: Validate**

Run: `bash -n init.3.pods.sh && shellcheck -x init.3.pods.sh`

**Step 4: Commit**

```bash
git add init.3.pods.sh
git commit -m "pods: extract local-path-provisioner version to variable"
```

---

### Task 12: Final validation + update docs

**Files:**
- Modify: `docs/lib.md` (add `detect_public_iface` to the table)

**Step 1: Run full validation**

```bash
bash -n lib.sh && bash -n init.1.vps.sh && bash -n init.2.rke2.sh && bash -n init.3.pods.sh && shellcheck -x lib.sh init.1.vps.sh init.2.rke2.sh init.3.pods.sh
```

Expected: Clean (only pre-existing SC2034 warnings for exported globals)

**Step 2: Update docs/lib.md**

Add `detect_public_iface()` to the System Detection table:

```markdown
| `detect_public_iface()` | `PUBLIC_IFACE` | Default-route interface via `ip route` |
```

**Step 3: Commit**

```bash
git add docs/lib.md
git commit -m "docs: add detect_public_iface to lib.md reference"
```
