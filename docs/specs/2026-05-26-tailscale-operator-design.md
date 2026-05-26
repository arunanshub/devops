# Tailscale Operator — kubectl Access Without IP Updates

**Date:** 2026-05-26
**Status:** Approved

## Problem

`var.home_ip` gates both SSH (port 22) and the Kubernetes API (port 6443) in Hetzner firewall rules.
Every time the home ISP assigns a new public IP, the operator must:
1. Update `var.home_ip` in `infra/secrets.yaml` (SOPS re-encrypt)
2. Run `just apply` to push the updated Hetzner firewall rule
3. Wait for `kubectl` to work again

## Solution

Install the **Tailscale Kubernetes Operator** with API server proxy enabled as an ArgoCD-managed Helm app. The operator exposes the kube-apiserver over the Tailscale WireGuard mesh. Port 6443 is removed from the public internet entirely. `kubectl` is reconfigured once with `tailscale configure kubeconfig tailscale-operator` and never needs updating again.

SSH (`var.home_ip` for port 22) is addressed in a follow-on phase.

---

## Architecture

The operator lives in `kubernetes/base/infra/tailscale-operator/` as a multi-source ArgoCD Application — the same pattern as `sealed-secrets`, `cilium`, and `argocd`. A companion `resources/` subdir holds the OAuth SealedSecret as a raw manifest deployed via a third Application source.

```
kubernetes/base/infra/tailscale-operator/
├── application.yaml                          # 3-source ArgoCD Application
├── values.yaml                               # Helm values (oauth left empty)
└── resources/
    ├── kustomization.yaml
    └── operator-oauth.sealedsecret.yaml      # unseals to Secret "operator-oauth" in tailscale ns
```

The operator registers into the tailnet as `tailscale-operator` and proxies all `kubectl` traffic through Tailscale. `apiServerProxyConfig.mode=true` preserves full Kubernetes RBAC via Tailscale identity impersonation.

---

## Files Changed

### Created
| File | Purpose |
|------|---------|
| `kubernetes/base/infra/tailscale-operator/application.yaml` | ArgoCD Application (3-source Helm) |
| `kubernetes/base/infra/tailscale-operator/values.yaml` | Helm values |
| `kubernetes/base/infra/tailscale-operator/resources/kustomization.yaml` | Kustomize manifest list |
| `kubernetes/base/infra/tailscale-operator/resources/operator-oauth.sealedsecret.yaml` | OAuth SealedSecret (generated, then committed) |
| `infra/tailscale.tf` | Tailscale provider + ACL + OAuth client resources |
| `seal.just` | All `seal-*` recipes extracted from Justfile |

### Modified
| File | Change |
|------|--------|
| `kubernetes/base/infra/kustomization.yaml` | Add `tailscale-operator` path |
| `kubernetes/base/infra/appproject.yaml` | Add Tailscale Helm repo to `sourceRepos`; add `tailscale` namespace to `destinations` |
| `infra/firewall.tf` | Remove `hcloud_firewall.control_plane_api` + `hcloud_firewall_attachment.control_plane_api` |
| `infra/variables.tf` | Add `tailscale_api_key` and `tailscale_tailnet` variables |
| `infra/outputs.tf` | Add sensitive outputs for OAuth client ID and secret |
| `Justfile` | Replace `seal-*` recipes with `import 'seal.just'` |

---

## Tailscale Setup via OpenTofu

### One-time manual bootstrap
1. Sign up at tailscale.com (free personal plan)
2. Create a personal API key: Settings → Personal API keys
3. Add to `infra/secrets.yaml` (SOPS-encrypted):
   ```yaml
   tailscale_api_key: tskey-api-xxxx
   tailscale_tailnet: yourname@gmail.com   # or your tailnet org name
   ```

### `infra/tailscale.tf`
```hcl
terraform {
  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.17"
    }
  }
}

provider "tailscale" {
  api_key = var.tailscale_api_key
  tailnet = var.tailscale_tailnet
}

resource "tailscale_acl" "main" {
  acl = jsonencode({
    tagOwners = {
      "tag:k3s-operator" = ["autogroup:admin"]
    }
    acls = [{ action = "accept", src = ["*"], dst = ["*:*"] }]
  })
}

resource "tailscale_oauth_client" "operator" {
  description = "k3s tailscale-operator"
  scopes      = ["devices:core", "auth_keys"]
  tags        = ["tag:k3s-operator"]
}
```

### `infra/outputs.tf` additions
```hcl
output "tailscale_oauth_client_id" {
  value     = tailscale_oauth_client.operator.id
  sensitive = true
}

output "tailscale_oauth_client_secret" {
  value     = tailscale_oauth_client.operator.key
  sensitive = true
}
```

### `infra/variables.tf` additions
```hcl
variable "tailscale_api_key" {
  type      = string
  sensitive = true
}

variable "tailscale_tailnet" {
  type        = string
  description = "Tailscale tailnet name (e.g. yourname@gmail.com)"
}
```

After adding to `secrets.yaml`, run `just apply` — this provisions Hetzner resources + Tailscale ACL + OAuth client in one shot.

---

## Secret Handling

The operator expects a Secret named `operator-oauth` in the `tailscale` namespace with keys `client_id` and `client_secret`. When `oauth.clientId` and `oauth.clientSecret` are left empty in `values.yaml`, the Helm chart skips creating the secret and uses the pre-existing one.

### `seal.just` (new file, extracted from Justfile)
All four `seal-*` recipes live here. The `seal-tailscale-oauth` recipe reads credentials directly from Terraform outputs:

```makefile
seal-tailscale-oauth:
    #!/usr/bin/env bash
    set -euo pipefail
    client_id=$(cd {{justfile_dir()}}/infra && sops exec-env secrets.yaml 'tofu output -raw tailscale_oauth_client_id')
    client_secret=$(cd {{justfile_dir()}}/infra && sops exec-env secrets.yaml 'tofu output -raw tailscale_oauth_client_secret')
    kubectl create secret generic operator-oauth \
        --namespace tailscale \
        --from-literal=client_id="$client_id" \
        --from-literal=client_secret="$client_secret" \
        --dry-run=client -o yaml | \
    kubeseal --controller-namespace kube-system --format yaml \
        > {{k8s}}/base/infra/tailscale-operator/resources/operator-oauth.sealedsecret.yaml
```

### `Justfile` change
```makefile
import 'seal.just'
```
replaces the three existing `seal-*` recipe blocks.

---

## ArgoCD Application

Multi-source Application following the `sealed-secrets` convention. The `$values` ref source enables the Helm chart to read `values.yaml` from this repo. The third source deploys the SealedSecret from `resources/`.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tailscale-operator
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: infra
  sources:
    - repoURL: https://pkgs.tailscale.com/helmcharts
      chart: tailscale-operator
      targetRevision: "1.*"   # pin to latest 1.x at implementation time; check https://pkgs.tailscale.com/helmcharts
      helm:
        releaseName: tailscale-operator
        valueFiles:
          - $values/kubernetes/base/infra/tailscale-operator/values.yaml
    - repoURL: git@github.com:arunanshub/devops.git
      targetRevision: master
      ref: values
    - repoURL: git@github.com:arunanshub/devops.git
      targetRevision: master
      path: kubernetes/base/infra/tailscale-operator/resources
  destination:
    server: https://kubernetes.default.svc
    namespace: tailscale
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Sync wave:** `0` (default). The sealed-secrets controller is already running before this app syncs, so the `operator-oauth` SealedSecret will be unsealed promptly. If the operator pod starts before the secret is ready it will restart once and succeed.

---

## Terraform Cleanup

Remove from `infra/firewall.tf`:
```hcl
# DELETE both resources:
resource "hcloud_firewall" "control_plane_api" { ... }
resource "hcloud_firewall_attachment" "control_plane_api" { ... }
```

`var.home_ip` and `hcloud_firewall.main` (SSH rule) are unchanged — SSH gating is addressed in the follow-on Tailscale-on-nodes phase.

Run `just apply` once after commit to converge Hetzner state (firewall deletion).

---

## Laptop Setup (one-time)

After the operator pod is running and registered in the tailnet:
```bash
tailscale configure kubeconfig tailscale-operator
```

This rewrites `~/.kube/config` (or sets a new context) pointing at the Tailscale hostname. The `infra/kubeconfig.yaml` file generated by OpenTofu is no longer the primary access path.

---

## Rollout Order

1. Add `tailscale_api_key` + `tailscale_tailnet` to `infra/secrets.yaml`
2. `just apply` — provisions Tailscale ACL + OAuth client alongside Hetzner resources
3. `just seal-tailscale-oauth` — generates `operator-oauth.sealedsecret.yaml`
4. Commit all files; ArgoCD reconciles the operator
5. Verify operator pod running: `kubectl -n tailscale get pods`
6. Verify operator appears in Tailscale admin console
7. `tailscale configure kubeconfig tailscale-operator` on laptop
8. Verify `kubectl get nodes` works via Tailscale
9. `just apply` once more to remove `control_plane_api` firewall from Hetzner

---

## What This Does Not Change

- `var.home_ip` and SSH firewall rule — addressed in follow-on phase
- Hetzner API load balancer (`10.0.0.100`) — internal-only, not the source of pain
- Cloudflare tunnel — unchanged, public web UIs unaffected
- All existing ArgoCD apps and HTTPRoutes — untouched
