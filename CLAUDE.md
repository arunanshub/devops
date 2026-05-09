# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A self-managed k3s cluster on Hetzner Cloud, declared in OpenTofu and reconciled by ArgoCD.

- `infra/` — OpenTofu provisioning the Hetzner nodes, network, firewall, SSH key, API load balancer; writes `infra/kubeconfig.yaml` to disk for local use
- `kubernetes/bootstrap/` — helmfile + SOPS-encrypted secrets that run **once** to install the cluster's foundational components
- `kubernetes/infra/` — ArgoCD `Application` manifests that take over after bootstrap (app-of-apps via `kubernetes/root-application.yaml`)
- `kubernetes/monitoring/` — same pattern, but for kube-prometheus-stack

A second repo (`git@github.com:arunanshub/devops.git`) holds the non-secret Helm values consumed by the ArgoCD Applications via the multi-source `$values` pattern. The Applications reference values files at paths like `$values/kubernetes/infra/<app>/values.yaml`, which resolve into that other repo.

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

Cilium, hccm, and ArgoCD are installed by `kubernetes/bootstrap/helmfile.yaml`, then **adopted** by ArgoCD via `Application` manifests under `kubernetes/infra/<app>/`. For adoption to be a no-op diff under `ServerSideApply=true`:

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

1. Create `kubernetes/infra/<app>/application.yaml` and a sibling `values.yaml` (the values file is also referenced from `git@github.com:arunanshub/devops.git` via `$values` — keep both repos in sync if it's also referenced there)
2. Add the new path to `kubernetes/infra/kustomization.yaml`
3. Add the chart's `repoURL` to `kubernetes/infra/appproject.yaml` `sourceRepos`
4. If the app deploys to a namespace not yet in the AppProject `destinations`, add it
5. Commit; ArgoCD picks it up on next reconcile

## Network architecture (Hetzner-specific)

- Hetzner Cloud Network exists (`hcloud_network.main`, IPv4 only — Cloud Networks don't support IPv6)
- k3s runs with `flannel-backend: none`, `disable-kube-proxy: true`, `disable-cloud-controller: true`
- Cilium replaces all three: CNI, kube-proxy (`kubeProxyReplacement: true`), and works in **native routing** mode over the Hetzner Network (no VXLAN). hccm programs per-node pod-CIDR routes on the Cloud Network.
- WireGuard node-to-node encryption is enabled (`encryption.type: wireguard`, `nodeEncryption: true`)
- API endpoint reached by Cilium agents inside the cluster: `K8S_API_ENDPOINT` (exported in Justfile, default `10.0.0.100` = `local.lb_private_ip`). This is the private Hetzner API load balancer in front of all control planes.
- Current admin access is Option B: generated kubeconfig points at the bootstrap control plane's public IPv6, and public `6443` on control-plane nodes is gated on `var.home_ip` in `infra/firewall.tf`. The API load balancer public IPv4 is included in K3s TLS SANs for a future switch to public-LB admin HA, but is not the current kubeconfig endpoint.

## Files worth reading once

- `docs/bootstrap-pitfalls.md` — bootstrap-time landmines with diagnosis and fix
- `infra/scripts/init.sh.tpl` — the k3s install script
- `kubernetes/bootstrap/helmfile.yaml` — bootstrap order and `needs:` graph
- `Justfile` — operator UX entrypoints

## Things not to do

- Do not re-run `just argocd-bootstrap` after the root Application is applied (helmfile vs ArgoCD ownership conflict).
- Do not commit kubeconfig.yaml (already in `.gitignore`).
- Do not generate SOPS-encrypted Secret YAMLs from `kubectl get -o yaml` without stripping runtime metadata first.
- Do not change `helm.releaseName` on a live ArgoCD Application without also expecting to delete and recreate the underlying `Deployment` (selector immutability).
