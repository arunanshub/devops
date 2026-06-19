# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A self-managed k3s cluster on Hetzner Cloud, declared in OpenTofu and reconciled by ArgoCD.

- `infra/` — OpenTofu provisioning the Hetzner nodes, network, firewall, SSH key, API load balancer; writes `infra/kubeconfig.yaml` to disk for local use
- `kubernetes/bootstrap/` — helmfile + SOPS-encrypted secrets that run **once** to install the cluster's foundational components
- `kubernetes/base/infra/` — ArgoCD `Application` manifests that take over after bootstrap (app-of-apps via `kubernetes/root-application.yaml`)
- `kubernetes/base/monitoring/` — same pattern, but for kube-prometheus-stack
- `kubernetes/overlays/prod/` — production kustomize overlay; this is what `kubernetes/root-application.yaml` points ArgoCD at (`path: kubernetes/overlays/prod`)

This repo's git remote is `git@github.com:arunanshub/devops.git` — the same URL ArgoCD reads from. The multi-source `$values` pattern references values files at paths like `$values/kubernetes/base/infra/<app>/values.yaml` from this repo.

## Tooling

All required CLIs are pinned in `devbox.json`. Always work from `devbox shell` so versions match — notably `kubeseal@0.36.0` must match the in-cluster sealed-secrets controller, and `helmfile`/`kustomize` are needed for the bootstrap path.

The `Justfile` is the operator entrypoint. `just --list` shows every recipe. `KUBECONFIG` and `K8S_API_ENDPOINT` are exported at the top of the Justfile and propagate to all recipes.

Pre-commit checks (`lefthook.yml`): `tofu fmt/validate`, `yamlfmt`, `shellcheck`, `gitleaks`, `just --fmt`. Run via lefthook on commit.

## Bootstrap order

This is what a clean cluster build looks like. Steps 3–5 are one-shots that **must run in order** — see `docs/bootstrap-pitfalls.md` for what goes wrong if order slips.

1. `just apply` — provisions the Hetzner nodes and API load balancer, runs `infra/scripts/init.sh.tpl` as cloud-init, writes `infra/kubeconfig.yaml`
2. `just argocd-bootstrap` — applies the SOPS-decrypted hcloud Secret (via dependency recipe), then `helmfile apply` installs Gateway API CRDs + hccm before Cilium, then ArgoCD
3. `just argocd-ssh-bootstrap` — applies the ArgoCD repo SSH key
4. `just restore-sealed-secrets-key` — applies the sealed-secrets master key
5. `just argocd-root-bootstrap` — applies `kubernetes/root-application.yaml`, kicking off ArgoCD reconciliation of everything

After step 5, ArgoCD owns the cluster. **Do not re-run `just argocd-bootstrap` after this point** — helmfile and ArgoCD will fight for ownership of overlapping resources.

## Two patterns to know cold

### Helmfile→ArgoCD adoption

Cilium, hccm, and ArgoCD are installed by `kubernetes/bootstrap/helmfile.yaml`, then **adopted** by ArgoCD via `Application` manifests under `kubernetes/base/infra/<app>/`. For adoption to be a no-op diff under `ServerSideApply=true`:

- `helm.releaseName` in the ArgoCD `Application` must equal the helmfile release `name`. Helm derives `app.kubernetes.io/instance` (a selector label) from this — selectors are immutable, so a mismatch produces a permanent reconcile failure on `Deployment.spec.selector`.
- The bootstrap values file and the ArgoCD values file must **render to identical manifests**. The bootstrap file may be `.yaml.gotmpl` (helmfile-rendered, e.g. reading `K8S_API_ENDPOINT` from env); the ArgoCD file is plain YAML with the literal value. Both must produce the same output.

### SOPS file naming

`.sops.yaml` configures auto-encryption for any path matching `(\w+\.)?(secrets|sops)\.ya?ml$`. Always name files that should be encrypted as `*.sops.yaml` or `*.secrets.yaml` — `sops` will refuse to save plaintext to those paths, which prevents accidental commits.

When creating SealedSecret-bound or SOPS-bound Secret manifests, **strip runtime metadata** before encrypting: `creationTimestamp`, `resourceVersion`, `uid`, `ownerReferences`. These come from `kubectl get -o yaml` and cause apply conflicts (`resourceVersion`) or worse, garbage-collection of the secret post-apply (`ownerReferences` referencing a UID that doesn't exist in the new cluster).

## ArgoCD sync waves

`argocd.argoproj.io/sync-wave` orders reconciliation. Convention here:

- `-2`: `AppProject` (must exist before child Applications referencing it)
- `-1`: ArgoCD self-managing Application
- `1`: Cilium (network must come up before anything that needs pod networking)
- `2`: hccm (provides cloud-provider integration; depends on Cilium)
- default `0`: everything else

## Adding a new app under ArgoCD

1. Create `kubernetes/base/infra/<app>/application.yaml` and a sibling `values.yaml`
2. Add the new path to `kubernetes/base/infra/kustomization.yaml`
3. Add the chart's `repoURL` to `kubernetes/base/infra/appproject.yaml` `sourceRepos`
4. If the app deploys to a namespace not yet in the AppProject `destinations`, add it
5. Commit; ArgoCD picks it up on next reconcile via `kubernetes/overlays/prod`

## Network architecture (Hetzner-specific)

- Hetzner Cloud Network exists (`hcloud_network.main`, IPv4 only — Hetzner Cloud Networks (private overlay) don't support IPv6; servers themselves support IPv6 on public interfaces)
- k3s runs with `flannel-backend: none`, `disable-kube-proxy: true`, `disable-cloud-controller: true`
- Cilium replaces all three: CNI, kube-proxy (`kubeProxyReplacement: true`), and uses **VXLAN tunnel mode** (`routingMode: tunnel, tunnelProtocol: vxlan`). VXLAN is required because Hetzner's network cannot carry pod CIDRs from multiple clusters in ClusterMesh; native routing would break cross-cluster pod communication. hccm is still deployed for cloud-provider integration (LoadBalancer services, node labeling) but does not program pod-CIDR routes — VXLAN handles cross-node pod routing.
- WireGuard node-to-node encryption is enabled (`encryption.type: wireguard`, `nodeEncryption: true`, `persistentKeepalive: 25s`). WireGuard runs over IPv6 between nodes, adding 95 bytes of overhead per packet on Cilium ≥ 1.20.0-pre.3 (was 80 on ≤ pre.2, before Cilium corrected `WireguardOverhead` to reserve the 15-byte framing padding).
- **MTU is critical in this stack.** Effective cross-node path MTU = 1450 (Hetzner NIC) − 95 (WireGuard) − 50 (VXLAN) = **1305 bytes** (`cilium_wg0` = 1450 − 95 = **1355**; overlay route clamp = 1355 − 50 = 1305). On Cilium ≤ 1.20.0-pre.2 the chain was 1450 − 80 − 50 = 1320 with `cilium_wg0` = 1370. Cilium's PMTUD is set to `always` mode so oversized UDP/ICMP packets receive ICMP feedback instead of being silently dropped. See `docs/cilium-mtu-overlay-networking.md` for the full analysis. Use `just verify-mtu` to confirm the stack is healthy after any Cilium change.
- API endpoint reached by Cilium agents inside the cluster: `K8S_API_ENDPOINT` (exported in Justfile, default `10.0.0.100` = `local.lb_private_ip`). This is the private Hetzner API load balancer in front of all control planes.
- Current admin access is Option B: generated kubeconfig points at the bootstrap control plane's public IPv6, and public `6443` on control-plane nodes is gated on `var.home_ip` in `infra/firewall.tf`. The API load balancer public IPv4 is included in K3s TLS SANs for a future switch to public-LB admin HA, but is not the current kubeconfig endpoint.

## Files worth reading once

- `docs/bootstrap-pitfalls.md` — bootstrap-time landmines with diagnosis and fix
- `docs/cilium-mtu-overlay-networking.md` — VXLAN+WireGuard MTU postmortem: what broke, what was fixed, what to never try again
- `infra/scripts/init.sh.tpl` — the k3s install script
- `kubernetes/bootstrap/helmfile.yaml` — bootstrap order and `needs:` graph
- `Justfile` — operator UX entrypoints; `just verify-mtu` is the post-bootstrap networking health check

## Doc-backed changes only (hard rule — learned the hard way)

Do **not** apply an infra config change on the strength of assumption or training-data memory.
**Verify the specific flag / field / value / behavior against current upstream docs *before* you
ship it** — Context7 or exa pinned to the running version, the tool's own `--help`, or the live API
(`kubectl explain`, the live CRD). This is mandatory for anything touching k3s, the kubelet, Cilium,
chart values, or ArgoCD behavior. If you cannot cite a doc URL or live-command output for a claim,
do not act on it.

- A `kubelet-arg` is valid only if the kubelet exposes it as a **CLI flag**. Many
  KubeletConfiguration *fields* (e.g. `maxParallelImagePulls`) are **not** CLI flags and make k3s
  crash-loop with `unknown flag`. `--check` / `ansible-lint` / `helm template` **cannot** catch a
  runtime flag rejection — only the actual restart does. The render passing is not proof.
- Touch k3s / node config only via ansible one-shots with `serial: 1` + `max_fail_percentage: 0` +
  a node-Ready gate, so a bad change halts on the first node with etcd quorum (2/3) intact; revert =
  remove the drop-in + restart. Confirm `:6443`/API recovery does not depend on the node being
  restarted (the operator kubeconfig points at cp-1; readiness waits must tolerate that — use
  `default([])` in the `until`).
- This rule exists because on 2026-06-19 an unverified `--max-parallel-image-pulls` kubelet-arg
  crash-looped k3s on cp-1 (26 restarts). The safety net held (quorum preserved, clean revert), but
  it was avoidable by reading the docs first. See memory `k3s-max-parallel-image-pulls-not-a-flag`.

## Things not to do

- Do not re-run `just argocd-bootstrap` after the root Application is applied (helmfile vs ArgoCD ownership conflict).
- Do not commit kubeconfig.yaml (already in `.gitignore`).
- Do not generate SOPS-encrypted Secret YAMLs from `kubectl get -o yaml` without stripping runtime metadata first.
- Do not change `helm.releaseName` on a live ArgoCD Application without also expecting to delete and recreate the underlying `Deployment` (selector immutability).
- Do not change the kustomize source path of the root Application (in `kubernetes/root-application.yaml`) and push in the same commit that restructures the directory layout. ArgoCD reads the in-cluster Application object's source, not the file. If the in-cluster source still points at the old path and the old `kustomization.yaml` is gone, ArgoCD falls back to plain-directory mode, applies any YAML it finds directly (including `root-application.yaml`), and with `prune: true` can delete all managed apps — and the root Application itself. The safe order: re-apply `kubernetes/root-application.yaml` via `just argocd-root-bootstrap` **before** pushing the commit that removes the old kustomization entry point. See `docs/kustomize-overlay-restructure.md`.
