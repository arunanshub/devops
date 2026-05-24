# Kustomize & AppProject Reorganization

**Date:** 2026-05-24
**Status:** Approved for implementation

## Problem

`kubernetes/base/infra/` mixes 16 ArgoCD Applications under a single `infra` AppProject that spans everything from CNI configuration to Hetzner block storage to optional operational tooling. Two specific issues:

1. **Cloud-provider coupling in base.** `hcloud-ccm`, `hcloud-csi`, and `hcloud-secret` live in `base/infra/`, which makes the base non-portable. Running the cluster against a local k3d environment would pull in Hetzner-specific apps that fail (no metadata service reachable).

2. **One AppProject as a dumping ground.** The `infra` AppProject covers `kube-system`, `argocd`, `system-upgrade`, `traefik`, `cert-manager`, `keda`, `vpa`, and `cloudflared` — six fundamentally different namespace groups. AppProjects are governance entities scoped to source repos + destination namespaces. Mixing cluster kernel namespaces with service platform namespaces dilutes that governance.

Secondary inconsistency: `argocd-route` lives in `base/infra/` while functionally-equivalent `traefik-route` and `hubble-route` are Kustomize Components. This pattern should be uniform.

## Design Principles

- **Directories are the organizing first-class citizen.** AppProjects follow the directory grouping rather than the other way around; they exist because ArgoCD requires them and to enforce namespace-scoped governance.
- **AppProject ↔ namespace group.** One AppProject per distinct namespace-ownership boundary. Don't create an AppProject just because a directory moved.
- **`base/` is cloud-agnostic.** Anything that requires a specific cloud provider (Hetzner API, cloud metadata service, block storage driver) belongs in a component enabled by the prod overlay.
- **Components are the opt-in layer.** `kind: Component` kustomizations in `components/` let the prod overlay explicitly list what it wants. A future `dev` overlay can compose a different subset.

## AppProject Split

Three AppProjects after the change (up from two).

### `infra` (unchanged name)

Governs the cluster kernel: GitOps engine, secret management, CNI, and anything that deploys into cluster-managed namespaces.

**Destinations:** `kube-system`, `argocd`, `system-upgrade`, `cilium-secrets`

**Always-on Applications (base/infra/):**
- `argocd` — GitOps engine (wave -1, self-managing)
- `gateway-api-crds` — CRDs required by Cilium and Traefik
- `sealed-secrets` — in-cluster secret decryption
- `cilium` — CNI, kube-proxy replacement, WireGuard encryption (wave 1)

**Component Applications (project: infra):**
- `hetzner` component — hcloud-ccm (wave 2), hcloud-csi, hcloud-secret
- `maintenance` component — kured, system-upgrade-controller + plans
- `argocd-route` component — HTTPRoute exposing ArgoCD UI (→ argocd ns)
- `hubble-route` component — HTTPRoute exposing Hubble UI (→ kube-system ns)
- `argocd-app-controller-vpa` component — VPA for ArgoCD app controller (→ argocd ns)

---

### `platform` (new)

Governs the service platform layer: ingress, certificate management, autoscaling, and the external access tunnel. These apps live in their own dedicated namespaces. Cluster survives their removal; applications do not.

**Destinations:** `traefik`, `cert-manager`, `keda`, `vpa`, `cloudflared`

**Always-on Applications (base/platform/):**
- `traefik` — Gateway API ingress controller + dashboard (wave 0)
- `cert-manager` — TLS certificate management
- `keda` — event-driven autoscaling
- `vpa` — vertical pod autoscaler controller

**Component Applications (project: platform):**
- `access` component — cloudflared (prod-only; not needed for local dev)
- `traefik-route` component — HTTPRoute exposing Traefik dashboard (→ traefik ns)
- `traefik-scaling` component — KEDA ScaledObject + VPA for Traefik (→ traefik ns)
- `cainjector-vpa` component — VPA for cert-manager cainjector (→ cert-manager ns)

---

### `monitoring` (unchanged)

No changes. Applications, AppProject, and namespace remain as-is.
`tempo-vpa` component keeps `project: monitoring` (deploys to monitoring ns).

## Directory Layout

```
kubernetes/
  base/
    infra/                          ← project: infra (cluster kernel)
      appproject.yaml               destinations: kube-system, argocd, system-upgrade, cilium-secrets
      kustomization.yaml
      argocd/
      cilium/
      gateway-api-crds/
      sealed-secrets/

    platform/                       ← NEW — project: platform (service layer)
      appproject.yaml               destinations: traefik, cert-manager, keda, vpa, cloudflared
      kustomization.yaml
      cert-manager/
      keda/
      traefik/
      vpa/

    monitoring/                     ← unchanged

  components/                         ← flat — one top-level dir per component (existing pattern)
    hcloud-ccm/                     ← NEW (moved from base/infra/, project: infra)
      kustomization.yaml            (kind: Component)
      application.yaml              ($values path: kubernetes/components/hcloud-ccm/values.yaml)
      values.yaml

    hcloud-csi/                     ← NEW (moved from base/infra/, project: infra)
      kustomization.yaml            (kind: Component)
      application.yaml              ($values path: kubernetes/components/hcloud-csi/values.yaml)
      values.yaml

    hcloud-secret/                  ← NEW (moved from base/infra/, project: infra)
      kustomization.yaml            (kind: Component)
      application.yaml
      sealed-secret.yaml

    cloudflared/                    ← NEW (moved from base/infra/, project: platform)
      kustomization.yaml            (kind: Component)
      application.yaml
      resources/
        deployment.yaml
        metrics-service.yaml
        namespace.yaml
        scaledobject.yaml
        sealed-tunnel-token.yaml
        servicemonitor.yaml
        kustomization.yaml

    kured/                          ← NEW (moved from base/infra/, project: infra)
      kustomization.yaml            (kind: Component)
      application.yaml              ($values path: kubernetes/components/kured/values.yaml)
      values.yaml

    system-upgrade-controller/      ← NEW (moved from base/infra/, project: infra)
      kustomization.yaml            (kind: Component)
      application.yaml
      plans-application.yaml

    argocd-route/                   ← NEW (moved from base/infra/, project: infra)
      kustomization.yaml            (kind: Component)
      application.yaml
      resources/
        httproute.yaml
        kustomization.yaml

    traefik-route/                  ← existing — project: infra → platform
    traefik-scaling/                ← existing — project: infra → platform
    cainjector-vpa/                 ← existing — project: infra → platform

    hubble-route/                   ← existing — stays project: infra
    argocd-app-controller-vpa/      ← existing — stays project: infra
    tempo-vpa/                      ← existing — stays project: monitoring

  overlays/
    prod/
      kustomization.yaml            ← resources: ../../base; components: all of the above
```

## Changes Required

### New files
- `base/platform/appproject.yaml` — new AppProject (wave -2; sourceRepos: git repo + traefik/cert-manager/keda/vpa chart repos; destinations: traefik, cert-manager, keda, vpa, cloudflared)
- `base/platform/kustomization.yaml`
- `base/platform/{traefik,cert-manager,keda,vpa}/` — whole dirs moved from `base/infra/`
- `components/hcloud-ccm/` — new component (whole dir moved from `base/infra/hcloud-ccm/`)
- `components/hcloud-csi/` — new component (whole dir moved from `base/infra/hcloud-csi/`)
- `components/hcloud-secret/` — new component (whole dir moved from `base/infra/hcloud-secret/`)
- `components/cloudflared/` — new component (whole dir moved from `base/infra/cloudflared/`)
- `components/kured/` — new component (whole dir moved from `base/infra/kured/`)
- `components/system-upgrade-controller/` — new component (whole dir moved from `base/infra/system-upgrade-controller/`)
- `components/argocd-route/` — new component (whole dir moved from `base/infra/argocd-route/`)

Each moved directory gains a `kustomization.yaml` with `kind: Component`.

### Modified files
- `base/infra/kustomization.yaml` — retain only: appproject, argocd, gateway-api-crds, sealed-secrets, cilium
- `base/infra/appproject.yaml` — remove destinations: traefik, cert-manager, keda, vpa, cloudflared; remove sourceRepos: traefik chart, cert-manager chart, keda chart, vpa chart
- `base/kustomization.yaml` — add `platform/` to resources
- `overlays/prod/kustomization.yaml` — add 7 new components (hcloud-ccm, hcloud-csi, hcloud-secret, cloudflared, kured, system-upgrade-controller, argocd-route)
- `components/hcloud-ccm/application.yaml` — update `$values` path from `kubernetes/base/infra/hcloud-ccm/values.yaml` → `kubernetes/components/hcloud-ccm/values.yaml`
- `components/hcloud-csi/application.yaml` — update `$values` path similarly
- `components/kured/application.yaml` — update `$values` path from `kubernetes/base/infra/kured/values.yaml` → `kubernetes/components/kured/values.yaml`
- `components/traefik-route/application.yaml` — `project: infra` → `project: platform`
- `components/traefik-scaling/application.yaml` — `project: infra` → `project: platform`
- `components/cainjector-vpa/application.yaml` — `project: infra` → `project: platform`
- All Applications moving to `base/platform/` (traefik, cert-manager, keda, vpa) — update `$values` paths from `kubernetes/base/infra/<app>/values.yaml` → `kubernetes/base/platform/<app>/values.yaml`

### Deleted source locations (replaced by above)
- `base/infra/traefik/`, `cert-manager/`, `keda/`, `vpa/` — moved to `base/platform/`
- `base/infra/cloudflared/`, `hcloud-ccm/`, `hcloud-csi/`, `hcloud-secret/`, `kured/`, `system-upgrade-controller/`, `argocd-route/` — moved to `components/`

## Migration Safety

The in-cluster ArgoCD state does not change:
- AppProject `infra` already exists and keeps the same name.
- All existing Application names are preserved — ArgoCD identifies Applications by name, not path.
- The new `platform` AppProject must be applied **before** any Application referencing `project: platform` is synced. Sync wave `-2` on `base/platform/appproject.yaml` guarantees this ordering within a single sync operation.
- The three components with updated `project:` values (`traefik-route`, `traefik-scaling`, `cainjector-vpa`) will show a diff on next sync. ArgoCD allows re-assigning an Application to a different project as long as the target project already exists and permits the destination namespace.

## What Does Not Change

- AppProject name `infra` — no Application `project:` fields need updating except the three noted above.
- All Application **names** — ArgoCD UI entries are unaffected.
- All values files — paths like `kubernetes/base/infra/cilium/values.yaml` and `kubernetes/base/infra/traefik/values.yaml` move with their app directory; the ArgoCD multi-source `$values` ref will need updating in those Application manifests.
- Sync waves — all existing annotations stay as-is.
- `monitoring/` — zero changes.
- Bootstrap path (`kubernetes/bootstrap/`) — zero changes.

## Non-Goals

- Renaming AppProject `infra` to `core`.
- Multi-environment overlays (a `dev/` overlay skeleton is future work, not part of this change).
- Moving monitoring components between AppProjects.
- Introducing per-environment image tag pinning or replica-count patches (the work-project pattern; not relevant for a single-env homelab).
