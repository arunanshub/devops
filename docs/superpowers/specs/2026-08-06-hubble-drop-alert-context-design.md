# Hubble Drop Alert Context

## Goal

Stop Traefik's unused daily version check and make Hubble drop notifications identify the traffic that Cilium denied.

## Design

- Set `global.checkNewVersion` and `global.sendAnonymousUsage` to `false` in the Traefik Helm values.
- Add source and destination namespace, workload, and IP labels plus traffic direction to the Hubble `drop` metric. Apply the same setting to the bootstrap and Argo CD Cilium values.
- Keep the existing alert threshold and reason coverage. Put the new context labels in the alert summary and description so the notification shows the denied path without a live Hubble query.
- Update the networking documentation and add regression checks for each invariant.

## Limits

Hubble drop metrics do not carry the destination port or DNS name. Persistent Hubble flow logs remain out of scope. The added IP labels increase time-series cardinality, but only dropped flows create these series. This is acceptable for the current three-node cluster and its low drop volume.

Cilium reads this static metric configuration when each agent starts. After GitOps sync, restart one Cilium pod at a time and wait for the node agent to become ready before continuing. Do not use a bulk DaemonSet restart.

## Validation

Run the focused regression tests first, then the full Go tests, lint, bootstrap-to-Argo adoption check, pinned Helm renders, production Kustomize validation, server-side dry-run, and whitespace checks.
