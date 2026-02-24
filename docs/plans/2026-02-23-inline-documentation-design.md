# Inline Documentation Design

## Goal

Replace external `docs/*.md` files with self-contained inline documentation in each script, so that each `.sh` file is the single source of truth for both behavior and explanation.

## What Changes

1. **Each script gets a header summary block** (top-of-file comment) that condenses the current `docs/*.md` content: purpose, usage, interactive steps, what-it-does table, output, and next steps.

2. **Block-level inline comments** are added throughout each script, explaining logical groups of 3-10 lines. Comments cover:
   - **What** the block does
   - **Why** the specific values/approach was chosen (especially for security settings, sysctl values, Helm chart options)

3. **`docs/*.md` files are deleted.** The `docs/plans/` directory is kept for design docs.

## Comment Style

- Comments placed **above** the block they describe
- 1-3 lines per block; longer for security-critical decisions
- No comments on obvious lines (`echo ""`, `log "Done"`, basic variable assignments)
- No explanation of bash syntax — audience is sysadmins, not bash beginners
- `what + why` for config values (e.g., "MaxAuthTries 3 — low enough to block brute force, high enough for legitimate typos")
- `what happens` for system commands (e.g., "Reset UFW to clean state, then deny all incoming by default")
- `explain the branching` for conditionals (e.g., "K8s nodes split traffic: public=SSH only, private=all")

## Files Affected

| File | Action |
|------|--------|
| `lib.sh` | Add header summary + inline comments |
| `init.1.vps.sh` | Add header summary + inline comments |
| `init.2.rke2.sh` | Add header summary + inline comments |
| `init.3.pods.sh` | Add header summary + inline comments |
| `docs/lib.md` | Delete |
| `docs/init.1.vps.md` | Delete |
| `docs/init.2.rke2.md` | Delete |
| `docs/init.3.pods.md` | Delete |

## Implementation Order

1. `lib.sh` — smallest, establishes comment patterns
2. `init.1.vps.sh` — heaviest security content, most "why" explanations
3. `init.2.rke2.sh` — RKE2/K8s-specific decisions
4. `init.3.pods.sh` — Helm chart values, component dependencies
5. Delete `docs/*.md` files
