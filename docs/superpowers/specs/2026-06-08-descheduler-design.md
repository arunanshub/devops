# Descheduler Component Design

**Date:** 2026-06-08  
**Status:** Approved

## Problem

Rolling node replacements (e.g., cpx32→cx33 migration) drain nodes one at a time. When a node comes back empty, the scheduler never re-balances existing pods — it only places *new* pods. The result is a permanently skewed distribution until pods restart for unrelated reasons.

Observed: after the cx33 migration, cp-3 carried ~25 workload pods (1006m CPU / 75% memory) while cp-1 carried 1 (393m CPU / 17% memory).

## Solution

Deploy the [kubernetes-sigs/descheduler](https://github.com/kubernetes-sigs/descheduler) as a CronJob. It runs periodically, identifies underutilized and overutilized nodes via actual metrics, and evicts pods from overloaded nodes so the scheduler replaces them on emptier nodes.

**Scheduler defaultConstraints deliberately excluded.** Passing `--config` to k3s's embedded scheduler disables all CLI flags k3s normally injects. Replicating them in a `KubeSchedulerConfiguration` file is fragile across k3s upgrades and requires ansible on all 3 CP nodes. Not worth it — the descheduler covers both the reactive case (drain skew) and the ongoing preventive case.

## Component Location

```
kubernetes/components/descheduler/
  kustomization.yaml
  application.yaml
  values.yaml
```

Wired into `kubernetes/overlays/prod/` (kustomization `components:`) and `kubernetes/base/infra/` (appproject).

Note: `kind: Component` kustomizations must be referenced via `components:` not `resources:`, so the Application lives in the prod overlay alongside hcloud-csi, kured, etc. The AppProject changes stay in `base/infra/appproject.yaml` since that is a static resource, not a Component.

## ArgoCD Application

- **Project:** `infra`
- **Chart:** `descheduler` from `https://kubernetes-sigs.github.io/descheduler/`
- **Version:** `0.34.0` (tracks k8s 1.34; Renovate manages upgrades)
- **Namespace:** `descheduler` (dedicated; not kube-system)
- **Pattern:** multi-source Helm with `$values` ref (same as hcloud-csi)
- **Sync wave:** `0` (default; no ordering dependency)

## Helm Values

### Mode

`kind: CronJob`, `schedule: "0 */6 * * *"` (every 6 hours).

- Default chart schedule (`*/2 * * * *`) is far too aggressive for a homelab.
- Daily at 2am converges too slowly after a drain (3+ days to fully rebalance).
- Every 6 hours converges within 24 hours and is operationally quiet.

### Policy

`deschedulerPolicyAPIVersion: descheduler/v1alpha2` with a single `default` profile.

**Plugins enabled:**

| Plugin | Extension point | Purpose |
|---|---|---|
| `LowNodeUtilization` | `balance` | Primary rebalancer: evicts from overloaded nodes to underloaded ones |
| `RemoveDuplicates` | `balance` | Ensures no two replicas of the same Deployment land on the same node |

**LowNodeUtilization thresholds:**

```
thresholds (underutilized):    cpu: 20, memory: 20, pods: 20
targetThresholds (overloaded): cpu: 50, memory: 50, pods: 50
```

The 20–50% gap zone is intentional: nodes in this band are left alone, preventing thrash where a freshly rebalanced node is immediately re-targeted.

**Metrics source:** `metricsUtilization.source: KubernetesMetrics` — uses actual CPU/memory from metrics-server (already running as `metrics-server` in kube-system) rather than resource requests. Requests lag actual usage because VPA adjusts them on a schedule; actual metrics reflect ground truth.

### Safety guardrails

- `nodeFit: true` on DefaultEvictor — only evict a pod if it can actually reschedule on another node (prevents eviction into a scheduling dead-end)
- `evictionLimits.node: 5` — max 5 pods evicted from any single node per cycle
- `maxNoOfPodsToEvictTotal: 15` — global per-run budget
- Descheduler uses the **Eviction API**, so PodDisruptionBudgets are honoured automatically
- DaemonSet pods and static pods (k3s control-plane components) are excluded by DefaultEvictor automatically — no namespace exclusions needed
- **PVC-backed pods are NOT in `extraEnabled`** — this keeps them protected by default. Evicting RWO PVC pods causes CSI detach/reattach downtime; for single-replica stateful workloads (vmsingle, grafana, tempo, and any future Postgres) this is an outage. Stateless pod rebalancing is sufficient to fix drain skew.

### No namespace exclusions

Excluding `kube-system` would prevent `coredns`, `hubble-relay`, `local-path-provisioner`, and others on cp-3 from being rebalanced — counterproductive. Static pods (etcd, kube-apiserver) and DaemonSets (cilium, kured, node-exporter) are already protected by the DefaultEvictor's built-in rules.

### Resource requests for descheduler itself

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi
priorityClassName: system-cluster-critical
```

The descheduler is API-server-bound, not compute-intensive. `system-cluster-critical` prevents it from being evicted by its own decisions.

## AppProject Changes

- Add `https://kubernetes-sigs.github.io/descheduler/` to `sourceRepos`
- Add `descheduler` namespace to `destinations`

## Files Modified

| File | Change |
|---|---|
| `kubernetes/components/descheduler/kustomization.yaml` | new |
| `kubernetes/components/descheduler/application.yaml` | new |
| `kubernetes/components/descheduler/values.yaml` | new |
| `kubernetes/overlays/prod/kustomization.yaml` | add `../../components/descheduler` under `components:` |
| `kubernetes/base/infra/appproject.yaml` | add repoURL + descheduler destination |
