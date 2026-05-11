# Kustomize Base/Overlay Restructure — Incident and Best Practices

## What changed

The `kubernetes/` directory was restructured from a flat resource aggregator to a proper kustomize base/overlay layout:

```
Before                          After
──────────────────────────────  ──────────────────────────────────────
kubernetes/                     kubernetes/
  kustomization.yaml              kustomization.yaml  (safety redirect)
  infra/                          base/
    kustomization.yaml              infra/
    cilium/                           kustomization.yaml
    ...                               cilium/
  monitoring/                         ...
    kustomization.yaml              monitoring/
    ...                               kustomization.yaml
  root-application.yaml               ...
                                overlays/
                                  prod/
                                    kustomization.yaml
                                root-application.yaml
```

`root-application.yaml` was updated from `path: kubernetes` to `path: kubernetes/overlays/prod`.

---

## The incident

The restructure was pushed as a single commit. At the time of push, the in-cluster root Application still pointed at `path: kubernetes` (the old source). `kubernetes/kustomization.yaml` had been deleted in the commit.

**What ArgoCD did:**

1. Detected the new commit, auto-synced root from `path: kubernetes`.
2. Found no `kustomization.yaml` at that path — fell back to **plain-directory mode**: applied every `.yaml` file found directly in `kubernetes/`. The only YAML there was `root-application.yaml`.
3. Applied `root-application.yaml`, updating root's own source to `path: kubernetes/overlays/prod`.
4. With `prune: true`, deleted all previously managed Applications that were not in the plain-directory output (cert-manager, cilium, hcloud-ccm, hcloud-csi, hcloud-secret, k3s-upgrade-plans, kube-prometheus-stack).
5. Root auto-synced from the new source (`kubernetes/overlays/prod`), which renders 13 Applications + 2 AppProjects + 1 Namespace.
6. `root-application.yaml` is not part of that kustomize output. Root had previously managed it as a plain-directory resource (step 2). With `prune: true`, root deleted `root-application.yaml` → deleted **itself**.
7. The 6 apps from waves −2 to 0 that were re-created in step 5 survived as orphans. The root Application was gone.

**Recovery:** `kubectl apply -f kubernetes/root-application.yaml` (i.e., `just argocd-root-bootstrap`) re-created root. Root synced from `kubernetes/overlays/prod`, re-created all 13 Applications, and all apps returned to Synced/Healthy within ~90 seconds.

---

## Root cause

ArgoCD's plain-directory fallback. When a kustomize root path has no `kustomization.yaml`, ArgoCD silently falls back to applying all YAML files in the directory as raw resources. Combined with `prune: true` on the root Application, any YAML that was previously managed but is no longer in the rendered output gets deleted — including, in this case, the root Application object itself.

---

## Best practices to follow

### 1. Never remove the old kustomize entry point and push before updating the in-cluster Application

The in-cluster Application object is the source of truth for what ArgoCD syncs from, not the file on disk. The sequence must be:

```
WRONG (what happened):
  1. Delete old kustomization.yaml, restructure, push
  2. ArgoCD picks up new commit → broken intermediate state

CORRECT:
  1. Add the new overlay structure alongside the old kustomization.yaml
  2. Re-apply root-application.yaml to update the in-cluster source: just argocd-root-bootstrap
  3. Confirm ArgoCD is syncing from the new path and is healthy
  4. Then (optionally) delete the old entry point in a follow-up commit
```

Or more simply: **update the in-cluster Application source before the old kustomize path disappears from git.**

### 2. Keep a safety kustomization.yaml at the directory root

`kubernetes/kustomization.yaml` now exists as a redirect to `overlays/prod`. If root's source path ever accidentally reverts to `path: kubernetes`, ArgoCD uses kustomize (not plain-directory mode) and renders the prod overlay correctly. This eliminates the failure mode entirely.

### 3. root-application.yaml must never enter the kustomize tree

`root-application.yaml` is applied out-of-band via `just argocd-root-bootstrap`. It must not appear inside any kustomize `resources:` list that root itself renders. If it does, a source-path change will cause root to self-prune on the next sync cycle (because the new rendered output won't include it).

The current layout is correct: `root-application.yaml` sits at `kubernetes/` top level, outside `base/`, `overlays/`, and `bootstrap/`.

### 4. Treat kustomize source-path migrations as two-phase changes

Any change to the `path:` of a live ArgoCD Application is a two-phase operation:

- **Phase 1:** Add the new path (new overlay, new kustomization.yaml) while the old path still works. Apply the updated Application object in-cluster.
- **Phase 2:** Remove the old path once ArgoCD is confirmed healthy on the new one.

Single-commit "move everything at once" only works safely if the Application object is updated in-cluster before the commit lands — i.e., the in-cluster state and the git state move together, not sequentially.
