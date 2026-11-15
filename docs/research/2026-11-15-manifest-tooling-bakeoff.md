# Manifest tooling bake-off: argocd-diff-preview vs KCL vs Holos

Date: 2026-11-15. Branch: `bakeoff/phase2`. Nothing merged or synced.

## Question

Which tool catches the two real values incidents before merge, with the fewest
lines and no Claude needed to read the result?

- **Null-default** (ca39949): dropping `cpu: null` from descheduler values let
  the chart's default 500m CPU limit come back.
- **Nesting** (7933d61): `priorityClassName` at the hcloud-csi values root is
  silently ignored; the chart only reads it under `controller.*` / `node.*`.

## Method

- **Baseline:** `helm template` of traefik 41.6.1, cilium 1.20.3, descheduler
  0.37.0, hcloud-csi 2.24.0 with the prod kube version (1.37.2) and the
  cluster's API versions, plus `kustomize build` of argocd-vpa. Rendered twice:
  all five are deterministic, cilium included. Spot-checked against live
  objects (cilium-config data, traefik args, descheduler resources, hcloud-csi
  priorityClassName, argocd VPA spec): all match.
- **Replay branches** (pushed, throwaway): `bakeoff/replay-control` (one real
  change each: traefik values, cilium values-only, argocd-vpa resource),
  `replay-null` (drops `cpu: null`), `replay-nest-base` (no priorityClassName)
  → `replay-nest` (adds it at the root).
- **Scope:** descheduler and hcloud-csi were added because the incidents
  happened there. Holos was tried on hcloud-csi only; KCL on the three charts
  that ship a `values.schema.json` (hcloud-csi, traefik, cilium). Neither
  touched argocd-vpa (raw manifests, nothing to type).

## Results

| | argocd-diff-preview 0.2.17 | KCL 0.13.3 (`kcl vet` + imported chart schema) | Holos 0.106.0 |
|---|---|---|---|
| Control (3 real changes) | all 3 shown, nothing else | n/a (validates, does not render) | hcloud-csi render identical to baseline |
| Null-default | **visible** in diff: `+ cpu: 500m` | not caught (no chart defaults) | not caught (inferred: values pass through to Helm) |
| Nesting | **missed**: "No changes found" (base and target both lack the key) | **fails**: `Cannot add member 'priorityClassName' to schema 'ValuesSchema'` | not caught, even with the schema imported and `close()` |
| Prod values today | n/a | red on all 3 charts (see below) | n/a |
| Source lines changed | 0 | 0 | every app rewritten in CUE |
| Renovate | unchanged | unchanged | chart versions move into CUE (inferred: `argocd` manager stops seeing them; a custom regex manager is needed) |
| Readable at 3am | a diff | a compiler error, but often a false one | CUE + generated schema |
| Maintenance | releases Oct 2026 | releases Oct 2026 | last release 2025-11-24; v1alpha6 tutorial uses the old field name |

### argocd-diff-preview

- Renders through a real Argo CD in an ephemeral k3d cluster. Its base renders
  match the helm baseline on all five apps, apart from representation (`0400`
  vs `256`, `annotations: null`) and traefik's `crds/`, which Argo CD applies
  and `helm template` omits. That is closer to prod than the baseline.
- Multi-source `$values` redirect works (the cilium values-only change shows).
- Costs:
  - CRD snapshot for `--preinstall-folder`, or charts that gate on
    `.Capabilities` (traefik, cilium ServiceMonitor) fail to render. Stripped to
    registration only (schemas, selectableFields, conversion removed; k3s,
    traefik, Gateway API, argoproj groups excluded; `api-approved` annotation
    kept for k8s.io groups): 74 CRDs, 39 KB. It must track prod.
  - A repo-creds secret (SSH deploy key) in CI: the repoURL is SSH.
  - Renders every app unless each Application has a `watch-pattern`
    annotation; values-only changes don't touch `application.yaml`.
  - Full pass without `--file-regex`: all 98 Applications (49 × 2 branches)
    rendered in 2m37s, and the diff listed only the 3 changed apps (no noise
    from the other 46). The `watch-pattern` optimisation is not needed at this
    size.
- It never fails a build. Null-default is caught only if the reviewer reads
  the diff. Nesting is a miss: an intended change that renders nothing looks
  identical to "no change".

### KCL (`kcl import -m jsonschema` + `kcl vet values.yaml`)

The catch comes from KCL closing the root object even though the chart's JSON
Schema leaves it open. Run against prod values (full counts):

| Chart | Errors on prod | Verdict |
|---|---|---|
| hcloud-csi | `storageClasses[].volumeBindingMode` ×2, `allowVolumeExpansion` ×2 | **true positive**: the chart hardcodes both; our keys are dead |
| hcloud-csi | `storageClasses[].extraParameters` ×1 | **false positive, dangerous**: the chart reads it (LUKS secret for `hcloud-volumes-encrypted`); "fixing" it would disable volume encryption |
| cilium | `policyAuditMode` ×1 | false positive: used by the chart, missing from its schema |
| traefik | importer emits invalid code (`"a" \| "b" \| None` enums, `>=` on `str \| int`) | the schema cannot be used without patching generated code |

On `replay-nest`, the only new error is the root `priorityClassName`. `kcl vet`
itself handles `null` values (minimal repro passes for YAML and JSON).
`kcl run --disable_none` would strip `null` and reintroduce the null-default
bug. Charts without a schema (descheduler) cannot be checked.

### Holos

- Values are an open struct. CUE's JSON-Schema import follows JSON Schema
  semantics (root `...`), so even a closed definition accepts unknown keys.
  Catching nesting needs hand-editing generated code.
- Moves chart versions out of `application.yaml` (see Renovate above).

## Environment notes (this machine only)

- Docker DNS carried a `domain.name` search domain with wildcard records; with
  `ndots:5`, `github.com` resolved to an unrelated host. Fixed with a k3s
  `--resolv-conf` via `--k3d-options`. GitHub-hosted runners don't need it.
- GitHub release-asset downloads time out here; installing Argo CD from
  `oci://ghcr.io/argoproj/argo-helm/argo-cd` avoids them.
- The run uses its own kubeconfig; prod was verified untouched.

## Exact command

```
argocd-diff-preview --repo arunanshub/devops --base-branch <base> --target-branch <target> \
  --cluster k3d --k3d-options "--image rancher/k3s:v1.37.2-k3s1 --k3s-arg --resolv-conf=/etc/k3s-resolv.conf@all --volume <resolv>:/etc/k3s-resolv.conf@all" \
  --preinstall-folder <crds> --argocd-chart-version 10.17.1 \
  --argocd-chart-url oci://ghcr.io/argoproj/argo-helm/argo-cd \
  --file-regex "/(traefik|cilium|argocd-vpa|descheduler|hcloud-csi)/application\.yaml$" \
  --output-app-manifests --timeout 900
```

(`base-branch/` and `target-branch/` are shallow clones; a repo-creds Secret
for `git@github.com:arunanshub` goes in `./secrets/`.)

## Findings

1. **No candidate gates both incidents.** diff-preview shows null-default and
   misses nesting. KCL's strict schema fails on nesting, but on prod it is red
   for every chart, with one false positive that would break encryption if
   "fixed". Holos catches neither.
2. **The nesting catch is a property of a closed root schema, not of KCL.**
   Any validator that closes the chart's schema would behave the same, with
   the same false positives from incomplete chart schemas.
3. **Holos is out:** no catch, every app rewritten, Renovate impact, stale.
4. **Real cleanup found:** hcloud-csi `volumeBindingMode`/`allowVolumeExpansion`
   are dead keys.

## Addendum: policy layer (Kyverno 1.19.2, conftest 0.71.1)

Policies run on the manifests argocd-diff-preview already renders, so they
add no render step. Files: `2026-11-15-bakeoff/`.

| | Kyverno | conftest (Rego) |
|---|---|---|
| Null-default replay | **fails**: `descheduler/Deployment/descheduler ... rule containers failed at path /spec/template/spec/containers/0/resources/limits/cpu/` | **fails** |
| Nesting replay | **fails**: `hcloud-csi-node` and `hcloud-csi-controller` at `/spec/template/spec/priorityClassName/` | not written (same shape) |
| Master (5 apps) | pass | pass |
| Full render, 49 apps | 3 failures, 1.5 s | 3 failures |
| Policy language | YAML pattern | Rego |

- **Live bug found:** all three KEDA Deployments run with a 1-CPU limit. The
  values comment says "No CPU limits, matching house style", but `cpu: null`
  is missing, so the chart default merged back. That is incident #1 again,
  live today. Neither diff-preview nor KCL could find it.
- Policies encode **intent**, not chart structure: they catch any way of
  breaking the invariant (wrong nesting, missing null, chart upgrade flipping
  a default) and never false-positive on keys a chart schema forgot.
- Cost: an invariant has to be written per intent. The CPU rule is generic
  (all workloads); the priority rule is per app.
- Gap: the CPU rule checks `containers`, not `initContainers`.
- Kyverno vs Rego: same verdicts. Kyverno's YAML pattern plus its error path
  is easier to read at 3am; Rego needs the language.
