# Correctness & Bug Fixes Design

Date: 2026-02-23
Approach: B (Bug fixes + convention alignment)

## HIGH — Production-breaking issues

### 1. Public interface hardcoded as `eth0` (init.1.vps.sh:295)

**Problem**: UFW K8s SSH rule uses `eth0`, but Hetzner servers use `enp1s0`/`ens3`. Potential SSH lockout.

**Fix**: Add `detect_public_iface()` to `lib.sh` using default route detection:
```bash
detect_public_iface() {
    PUBLIC_IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    [[ -n "$PUBLIC_IFACE" ]]
}
```
Use `${PUBLIC_IFACE}` in the UFW rule instead of `eth0`.

### 2. Shared memory append violates idempotency (init.1.vps.sh:458)

**Problem**: `echo >> /etc/fstab` is the only append in the codebase. Also ineffective on Ubuntu 24.04 where `/run/shm` is a symlink to `/dev/shm`.

**Fix**: Remove the `/run/shm` fstab block entirely.

### 3. Backgrounded `systemctl start` swallows errors (init.2.rke2.sh:395)

**Problem**: `systemctl start ... &` hides exit codes. Failures manifest as a 300s timeout with no error message.

**Fix**: Replace backgrounded start + manual wait loop with:
```bash
if ! timeout 300 systemctl start "$RKE2_SERVICE"; then
    err "${RKE2_SERVICE} failed to start"
    exit 1
fi
```

### 4. KUBECONFIG world-readable (init.2.rke2.sh:443)

**Problem**: `chmod 644` on `/etc/rancher/rke2/rke2.yaml` exposes cluster admin credential to all users.

**Fix**: `chmod 600`.

### 5. Helm values with secrets in world-readable `/tmp/` (init.3.pods.sh)

**Problem**: Passwords written to `/tmp/*.yaml` files that are never cleaned up.

**Fix**: Use `mktemp -d` with `chmod 700` and `trap 'rm -rf ...' EXIT` at script start. Write all values files there.

### 6. Rancher password in process list (init.3.pods.sh:577)

**Problem**: `--set bootstrapPassword=...` visible in `ps aux`.

**Fix**: Move to a values file passed via `-f`.

## MEDIUM — Incorrect defaults or logic errors

### 7. Leading space on `PermitRootLogin` (init.1.vps.sh:240)

**Problem**: Formatting bug in SSH config heredoc.

**Fix**: Remove the leading space.

### 8. SSH lockout when no user created (init.1.vps.sh:233)

**Problem**: `PermitRootLogin no` with no `AllowUsers` and no new user = locked out if no pre-existing non-root user.

**Fix**: Before writing SSH config, scan `/home/*/ssh/authorized_keys` for existing SSH users. Warn prominently if none found and require explicit confirmation.

### 9. CNI mismatch on joining servers (init.2.rke2.sh:133)

**Problem**: Operator can pick wrong CNI for joining server; no validation possible without kubectl.

**Fix**: Add a prominent `warn` before the CNI choice for joining servers.

### 10. Pinned local-path-provisioner version (init.3.pods.sh:253)

**Problem**: Hardcoded URL makes version updates hard to spot.

**Fix**: Extract to `LOCAL_PATH_VERSION` variable at script top.

## Convention alignment

### `.bashrc` appends in init.2.rke2.sh:434-438

**Problem**: Uses `grep -q` + `>>` pattern instead of `cat >` overwrite (violates CLAUDE.md convention).

**Fix**: Replace with `cat > /etc/profile.d/rke2.sh` containing PATH and KUBECONFIG exports. Removes `.bashrc` mutation entirely.
