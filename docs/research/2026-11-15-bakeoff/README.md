# Bake-off harness (evidence for ../2026-11-15-manifest-tooling-bakeoff.md)

Rendered manifests come from argocd-diff-preview (`--output-app-manifests`
writes `out/base/<app>.yaml` and `out/target/<app>.yaml`). Every check below
runs on those files or on the repo's values files. Tools are pinned in
`mise.toml` on this branch.

## Kyverno (rendered manifests)

    kyverno apply kyverno/no-cpu-limits.yaml kyverno/csi-critical-priority.yaml --resource out/target

## OPA / conftest (rendered manifests)

    conftest test --policy rego --all-namespaces out/target/*.yaml

## KCL (values against the chart's own values.schema.json)

    kcl import -m jsonschema -o schema.k --force <chart>/values.schema.json
    kcl vet kubernetes/components/hcloud-csi/values.yaml schema.k -s ValuesSchema --format yaml

## argocd-diff-preview

See "Exact command" in the scorecard. `k3s-resolv.conf` is the WSL DNS
workaround passed through `--k3d-options`; the CRD snapshot for
`--preinstall-folder` is prod's CRDs stripped to registration only.
