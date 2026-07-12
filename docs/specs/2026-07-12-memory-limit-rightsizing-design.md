# Memory limit right-sizing design

## Goal

Make the declared memory limits in git *true*, and remove two latent OOM traps, so
the cluster's configuration says what it actually does at runtime. This is a
**config-correctness** change, not a resource optimization.

## Background: why declared limits are fiction today

Every workload of interest runs under VPA. VPA's default `controlledValues` is
`RequestsAndLimits`, which — per the upstream API and features docs — **preserves the
limit-to-request ratio defined in the Pod spec** and scales the limit proportionally
whenever it raises the request. `maxAllowed` caps only the *request*; the limit is
therefore effectively uncapped.

The consequence is that the `limits.memory` we write in chart values is not the limit
that runs. VPA multiplies it by the observed request growth:

| Workload | Declared limit (git) | Live limit (VPA-inflated) | Ratio | Real per-pod peak (working set) |
|----------|----------------------|---------------------------|-------|---------------------------------|
| traefik  | `256Mi`              | ~1720Mi                   | 8:1   | 674Mi (load) / 326Mi (normal)   |
| vmsingle | `2Gi`                | ~4724Mi                   | 4:1   | 2922Mi                          |

Peak figures are `max_over_time(container_memory_working_set_bytes)` over 7 days from
the in-cluster VictoriaMetrics; the 21–30 day window shows the same single-pod peaks
(the larger aggregate numbers are two pods overlapping during a rollout).

The correctness problem has two faces:

1. **The declared value is a lie.** traefik's values say `limits.memory: 256Mi` with a
   comment "matches VPA maxAllowed"; the pod runs at ~1720Mi. vmsingle says `2Gi`
   "safety ceiling only"; the pod runs at ~4724Mi.
2. **Both declared values are *below* real peak.** traefik peaks at 674Mi but declares
   256Mi; vmsingle peaks at 2922Mi but declares 2Gi. If VPA were ever disabled, or its
   mode changed to leave the declared limit in force, both would OOM under load. VPA's
   ratio-inflation is currently the only thing giving them headroom — by accident.

The 107%/155% memory-*limit* commitment that prompted this work is a benign symptom:
limits are ceilings, not reservations, so over-commitment only means "not every pod can
hit its ceiling at once." The numbers that govern node stability are healthy — actual
usage is 63–69% of allocatable and requests (VPA-managed) sit at ~45%. Driving the
commitment number down is explicitly **not** the goal.

## Scope

Two workloads change: **traefik** and **vmsingle**. They are the only ones where VPA's
inflation both diverges materially from declared intent *and* the declared value is a
sub-peak trap.

### Left untouched, and why

- **argocd-application-controller** — 7d peak 2322Mi vs live limit ~2488Mi (1.07×). Tight
  already; the limit is earned.
- **tempo** — 1.27× headroom, deliberately tuned to escape the trace-ingestion OOM loop
  (see git history and the values comment). Must not shrink.
- **arunanshu-dev** — 1.08× vs its 2026-07-11 load-test peak; it is the KEDA-scaled,
  HN-hug-exposed app. Headroom is intentional.
- **Everything small** (cert-manager, kured, coredns, csi, keda, cloudflared, …) —
  absolute limits are small; any ratio there is rounding error, not risk.

### Non-goals

- Lowering the limit-commitment percentage as an end in itself.
- Touching requests (VPA already right-sizes them).
- Adding admission-time enforcement (LimitRange / ResourceQuota) — see the dedicated
  section on why that is unsafe here.

## Mechanism: `controlledValues: RequestsOnly` + an honest pinned limit

For both workloads, set the VPA container policy to `controlledValues: RequestsOnly`.
VPA then keeps right-sizing the **request** (scheduling stays accurate) but stops
scaling the **limit**. The limit becomes exactly what the chart declares — stable,
visible in git, and equal to intent.

**Hard invariant (must hold for every workload using RequestsOnly):**
`declared limit ≥ maxAllowed request`. Otherwise VPA drives the request past a frozen
limit and produces an invalid or OOM-prone Pod. Both configurations below satisfy it.

The pinned limit is sized above the measured real peak, not the `kubectl top` snapshot.

## Concrete changes

### traefik

Files: `kubernetes/components/traefik-scaling/resources/vpa.yaml` and
`kubernetes/base/platform/traefik/values.yaml`.

- VPA: add `controlledValues: RequestsOnly` to the `traefik` container policy; raise
  `maxAllowed.memory` from `256Mi` to `512Mi` (covers the normal 326Mi peak with margin
  so VPA can reserve appropriately).
- values: change `limits.memory` from `256Mi` to `1Gi` (comfortably above the 674Mi
  load peak); update the now-stale comment that claims the 256Mi limit "matches VPA
  maxAllowed."
- Invariant: limit `1Gi` (1024Mi) ≥ maxAllowed `512Mi`. ✓
- Peak coverage: limit `1Gi` > 674Mi peak. ✓

**GOMEMLIMIT note.** traefik wires `GOMEMLIMIT` from `limits.memory` via `resourceFieldRef`
(with `goMemLimitPercentage: 0`, so the chart's static calc is disabled and the live
cgroup limit is used). Lowering the effective limit from ~1720Mi to a stable 1Gi lowers
the GC target proportionally. traefik uses ≤674Mi even under load, so the 1Gi target
retains large headroom; GC pressure does not meaningfully change, and the cluster is
CPU-idle regardless. The `divisor: "1"` pin that keeps ArgoCD in sync stays as-is.

### vmsingle

Files: `kubernetes/components/monitoring-vpa/resources/vpa-vmsingle.yaml` and
`kubernetes/base/monitoring/victoria-metrics-k8s-stack/values.yaml`.

- VPA: add `controlledValues: RequestsOnly` to the `vmsingle` container policy; raise
  `maxAllowed.memory` from `2560Mi` to `3Gi`. (The current `2560Mi` cap is *below* the
  2922Mi peak, so VPA cannot presently reserve real peak; 3Gi corrects that.)
- values: change `limits.memory` from `2Gi` to `4Gi` (above the 2922Mi peak). Update the
  comments that reference "the 2Gi memory limit," including the `search.maxMemoryPerQuery`
  guard rationale, to reflect the 4Gi ceiling.
- Invariant: limit `4Gi` (4096Mi) ≥ maxAllowed `3Gi` (3072Mi). ✓
- Peak coverage: limit `4Gi` > 2922Mi peak; maxAllowed `3Gi` > 2922Mi peak. ✓
- RSS remains governed by `memory.allowedBytes: 512MB`, not the cgroup limit, so the 4Gi
  is a true safety ceiling rather than a working target. `updateMode` stays
  `InPlaceOrRecreate` (RequestsOnly does not change the in-place-resize behavior).

## Regression backstop: an alert, not enforcement

The genuine forward-looking concern is that a *future* chart re-introduces an inflated
ratio and the over-commitment creeps back unnoticed. The backstop is **detection**, added
to the existing `cluster-alerts` PrometheusRule
(`kubernetes/base/monitoring/cluster-alerts/resources/prometheusrule.yaml`) as a new group:

```yaml
- name: cluster.resources
  interval: 1m
  rules:
    - alert: NodeMemoryLimitCommitmentHigh
      expr: |
        sum by (node) (kube_pod_container_resource_limits{resource="memory"})
        / on(node)
        sum by (node) (kube_node_status_allocatable{resource="memory"})
        > 2
      for: 30m
      labels:
        severity: warning
      annotations:
        summary: "Node {{ $labels.node }} memory-limit commitment above 200%"
        description: "Sum of container memory limits on {{ $labels.node }} exceeds 2x allocatable for >30m. Limit over-commit is benign in itself (limits are ceilings, and actual usage is the real OOM guard), so this is a CREEP/REGRESSION signal, not a stability alert: it usually means a new or changed workload carries a large limit:request ratio that VPA is inflating. Check: kubectl get pods -A -o json | jq to find the largest memory limits, and confirm the workload's chart ratio. See docs/specs/2026-07-12-memory-limit-rightsizing-design.md."
```

Rationale for this signal over the alternatives:

- **Why node-commitment, not per-container ratio.** A per-container `limit/request` ratio
  alert is inherently noisy in this cluster: several existing workloads already sit at
  5–6:1 with harmless small absolute limits, and — critically — the two workloads we move
  to RequestsOnly will show a *high* ratio at idle (fixed 1Gi limit ÷ ~100Mi idle request
  ≈ 10:1) with no problem at all. Node-level commitment ignores harmless small-ratio
  workloads and only fires when a regression becomes *material*.
- **Threshold.** The current maximum node commitment is 155% (cp-2) and will *drop* after
  this change. 200% therefore sits clearly above post-fix steady state and fires only on
  genuine creep. `for: 30m` tolerates the transient two-pod overlap during rollouts.
- **This does not replace the usage-based guard.** Actual node memory-*usage* pressure is
  the real OOM safety net and is covered by the stack's standard node alerts; this rule is
  purely a config-drift detector.

## Why not LimitRange or ResourceQuota

Both were considered as enforcement backstops and rejected. They are namespace-scoped
admission policies designed to constrain workloads a platform team does *not* author. This
cluster is single-operator, GitOps-reviewed, and VPA-authoritative on resources, so the
premise those tools serve is absent — and on this cluster they are actively unsafe:

- **Rejection risk.** LimitRange `max` and ResourceQuota `limits.memory` are validating,
  not clamping. VPA's mutating webhook sets a (possibly inflated) limit first; the policy
  then *rejects* the Pod if it exceeds the cap, making the workload unschedulable. VPA
  1.6.0 (the running version) is not LimitRange- or ratio-aware and will set values
  outside the range. This is documented behavior and the exact failure in
  kubernetes/autoscaler#8401.
- **`maxLimitRequestRatio` is incompatible with the RequestsOnly fix.** With a fixed limit
  and a VPA-scaled idle request, the ratio spikes (~10:1 at idle) and trips the cap.
- **`default` injection is harmful here.** A LimitRange `default` injects a memory limit
  onto containers that intentionally run limitless (cilium-agent, cilium-envoy, hubble,
  metrics-server, vmagent, grafana), adding OOM exposure they do not have today.

The per-object request:limit ratio field that would make this clean
(kubernetes/autoscaler#8515 → AEP PR #8516) is an **open, unimplemented** proposal as of
2026-07-10; the closed issues were rolled into it, not fixed. When that ships in a released
VPA it would be the correct primitive to pin the ratio directly in the VPA object and
retire the RequestsOnly workaround. Until then, it is a watch item, not a dependency.

## Verification

After ArgoCD syncs each change:

- Confirm the live limit equals the declared limit and does not drift:
  `kubectl get pod <pod> -o jsonpath='{.spec.containers[*].resources}'`.
- Confirm the VPA still reports `RecommendationProvided` / `Provided` and the pod is not
  restart-looping.
- Re-run the `max_over_time` working-set query after a representative period and confirm
  it stays under the new ceiling (1Gi traefik, 4Gi vmsingle).
- Confirm `NodeMemoryLimitCommitmentHigh` is not firing (commitment should fall after the
  change) and that the rule loads (`vmalert` / Alertmanager rule list).

## Rollback

Revert the values and VPA edits; ArgoCD reconciles back to the prior state. No data is
touched and no PVC is involved, so rollback is a plain git revert. Removing the alert is
deleting the `cluster.resources` group.

## Follow-ups (out of scope)

- **Cross-app deploy race.** The one-commit rule is necessary but not sufficient: each
  workload's VPA and values live in *separate* ArgoCD Applications (traefik VPA →
  `traefik-scaling`, values → `traefik`; vmsingle VPA → `monitoring-vpa`, values →
  `victoria-metrics-k8s-stack`), which reconcile independently. The change was safe only
  because the VPA CR applies faster than the pod rollout and any transient inflation
  self-corrects once RequestsOnly is live; rollback has the same race reversed (low
  severity, self-correcting). To make it race-proof: co-locate each VPA with its workload's
  Application, or set a modest request floor in values so a mis-ordered sync cannot inflate
  the limit past ~2×.
- The now-fixed limits no longer auto-grow. The "workload outgrows its ceiling → OOM"
  direction (which `NodeMemoryLimitCommitmentHigh` does not watch) is covered by the stack's
  `KubePodCrashLooping` / `TooManyRestarts` / `KubeContainerWaiting` alerts.
- Watch kubernetes/autoscaler#8516; adopt the VPA-object ratio field when released.
- The `vpa-vmsingle.yaml` comment describes reasoning for `updateMode: Initial` while the
  value is `InPlaceOrRecreate`; reconcile the comment with the actual mode in a separate
  cleanup.
