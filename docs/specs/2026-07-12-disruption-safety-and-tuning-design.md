# Disruption-safety and tuning round design

## Goal

Close a small set of genuine, low-risk gaps found in a cluster-wide sweep (reliability,
Go runtime, probes, scaling, observability, storage): one HA gap, one un-applied
drain-safety fix, one free storage-utilisation bump, and one documentation fix. Each
mirrors an existing pattern or an already-decided doc item. This is polish on an
already-well-tuned cluster, not a rework.

## Background

Following the memory-limit right-sizing work (`2026-07-12-memory-limit-rightsizing-design.md`),
a broad sweep looked for optimisation/performance levers beyond memory. The overwhelming
result was "already optimal, deliberately" — CPU is idle, compression/MTU/spegel/BBR are
settled, cardinality and scrape topology are tuned, singleton SPOFs are inherent and
mitigated, GOMAXPROCS is correctly left at default (no CPU limits), and probes are sound.
Four small items survived as worth doing; one candidate (KEDA ingress responsiveness) was
investigated and deliberately rejected (recorded below).

## Scope

Four changes, each independent and individually revertible:

1. Add a PodDisruptionBudget for `arunanshu-dev`.
2. Apply the cloudflared drain-grace fix.
3. Extend vmsingle retention 14d → 28d.
4. Document why tempo's static `GOMEMLIMIT` is acceptable (no behaviour change).

### Non-goals

- No change to KEDA ingress scaling (decision recorded below).
- No change to GOMAXPROCS, cardinality, PVC sizing, tempo sampling, probes, or spread
  hardness — all verified optimal/deliberate.

## Change 1 — arunanshu-dev PodDisruptionBudget

**Why.** `arunanshu-dev` is the only multi-replica, public-facing workload without a PDB
(traefik, cloudflared, coredns all carry `maxUnavailable: 1`). Its spread is soft
(`whenUnsatisfiable: ScheduleAnyway`), so both replicas can transiently co-locate on one
node (e.g. right after a drain while nodes are cordoned). A subsequent voluntary drain
(kured reboot at 02:00–04:00 IST, or an SUC k3s upgrade) can then evict *both* at once →
~35s of 503s (readiness `initialDelaySeconds:5` + `minReadySeconds:30`) until reschedule.
The app has four unbudgeted voluntary-eviction sources (kured, SUC, descheduler
`RemoveDuplicates`, VPA Recreate-fallback). Blast radius is narrow (bounded co-location
window, off-peak trigger, behind Cloudflare), but it is the one unclosed eviction edge on a
public workload and the fix is an existing, proven pattern.

**Change.** New file `kubernetes/base/apps/arunanshu-dev/resources/pdb.yaml`:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: arunanshu-dev
  namespace: arunanshu-dev
spec:
  maxUnavailable: 1
  # AlwaysAllow so a crash-looping replica at the 2-replica floor can't make the budget
  # block eviction of the healthy one and wedge a kured/SUC drain.
  unhealthyPodEvictionPolicy: AlwaysAllow
  selector:
    matchLabels:
      app: arunanshu-dev
```

Add `pdb.yaml` to `kubernetes/base/apps/arunanshu-dev/resources/kustomization.yaml`
`resources:` list.

`maxUnavailable: 1` (not `minAvailable: 1`): at peak KEDA scale (8) `minAvailable:1` would
let a drain take out 7 at once; `maxUnavailable:1` correctly caps disruption to one pod
regardless of replica count. Selector `app: arunanshu-dev` matches the deployment's pod
labels (verified live).

## Change 2 — cloudflared drain grace

**Why.** Live `terminationGracePeriodSeconds` is the k8s default 30s, and no
`TUNNEL_GRACE_PERIOD` is set (cloudflared's own default grace is also 30s). So k8s SIGKILL
fires at ~30s — exactly when cloudflared's own drain would finish — cutting in-flight
requests on the terminating pod on every rollout/drain. This is verbatim
`docs/2026-06-19-cpu-latency-perf-scan.md` Tier A ("do now"); it was simply never landed.
Blast radius is bounded (min 2 replicas + PDB `maxUnavailable:1` keep the other replica
serving), so impact is only in-flight requests on the single draining pod during rollouts.

**Doc-verified (Cloudflare run-parameters):** env var `TUNNEL_GRACE_PERIOD` (default `30s`,
duration format); on SIGTERM cloudflared stops accepting new requests and waits for
in-progress ones up to this period.

**Change.** In `kubernetes/components/cloudflared/resources/deployment.yaml`:

- Add pod-spec field `terminationGracePeriodSeconds: 60` (under `spec.template.spec`, e.g.
  alongside `automountServiceAccountToken: false`).
- Add env var to the `cloudflared` container `env:` list:
  ```yaml
  - name: TUNNEL_GRACE_PERIOD
    value: 50s
  ```

`50s` drain inside a `60s` termination window leaves 10s clearance before SIGKILL.

## Change 3 — vmsingle retention 14d → 28d

**Why.** `retentionPeriod: "14d"` is a carried-over Prometheus default, not a pinned
constraint (`docs/k3s-checklist.md`; the migration doc calls 14d "disproportionate"). The
10Gi PVC is prepaid at Hetzner's volume floor and only ~3.2Gi used (~0.23Gi/day). VM RAM
scales with active-series count, not retention depth (older parts sit on NVMe, queried on
demand, bounded by `search.maxMemoryPerQuery: 256MB`). Doubling history is therefore ~free.

**Change.** In `kubernetes/base/monitoring/victoria-metrics-k8s-stack/values.yaml`, change
`vmsingle.spec.retentionPeriod` from `"14d"` to `"28d"`. 28d ≈ 6.4Gi projected, leaving
~3Gi of the 10Gi for VM background-merge headroom (don't chase the full 9Gi).

## Change 4 — document tempo's static GOMEMLIMIT (no behaviour change)

**Why.** tempo pins `GOMEMLIMIT: 800MiB` as a fixed value while its VPA runs
`InPlaceOrRecreate` + `RequestsAndLimits` (maxAllowed 1Gi request → proportional limit up
to ~1.6Gi). This is the same frozen-ceiling class fixed for traefik/vmsingle — when VPA
raises the limit past 1Gi, GOMEMLIMIT stays at 800MiB and GC works against a stale soft cap.
**We deliberately keep it static** rather than switch tempo to `RequestsOnly` (which would
surrender the deliberate WAL-replay OOM headroom that `RequestsAndLimits` provides) or wire
GOMEMLIMIT dynamically (raw `resourceFieldRef` bytes = 100% of limit, unsafe given tempo
needs non-heap headroom for WAL mmap/stacks/metrics-generator buffers). GOMEMLIMIT is a
*soft* target — Go throttles GC (≤50% CPU), it does not hard-OOM — and on this CPU-idle,
near-idle-trace cluster the only cost is wasted GC CPU during rare trace-burst-driven limit
raises. Acceptable; the action is to write that down, not change config.

**Change.** In `kubernetes/base/monitoring/tempo/values.yaml`, expand the comment above the
`GOMEMLIMIT` env (lines 21–22) to record: static-by-design; VPA is RequestsAndLimits for
WAL-replay OOM headroom; a stale-high limit only wastes GC CPU (soft target), which is
acceptable on this cluster; not switched to the traefik/vmsingle RequestsOnly pattern
because that would give up the OOM headroom. No value change.

## Rejected: KEDA ingress scaling responsiveness (recorded)

Considered aligning traefik/cloudflared KEDA responsiveness with arunanshu-dev's (15s poll +
custom behaviour). **Rejected.**

- Both ingress triggers scale on `rate(traefik_service_requests_total[2m])` — a **2-minute
  rate window**. That window, not the 30s `pollingInterval`, dominates reaction time;
  matching the app's 15s poll would shave ~15s against a 120s smoothing window — polishing
  the wrong knob.
- Under a sustained HN hug (minutes–hours), both tiers reach appropriate replica counts
  within ~2–3 min regardless of poll interval (window-dominated). The poll gap only matters
  for sub-minute microbursts, absorbed by the min-2 baseline + burstable headroom.
- The bottleneck under hug is the app's render/concurrency ceiling, not the throughput-bound
  proxy/egress. They correctly scale on different signals matched to different limits.
  Scaling the ingress faster adds connection waiting-room in front of a bottlenecked app,
  not throughput (consistent with the prior viral-hug analysis).
- If ingress hug-hardening is ever wanted, the real levers are the rate window (2m→1m) + a
  k6 load test (as arunanshu-dev had), and above all CF edge micro-caching of the HTML doc
  (CF/app-side) — not the KEDA poll interval.

## Verification

GitOps (ArgoCD auto-sync + selfHeal). After each push, nudge a refresh
(`kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite`)
and verify the live object, since the auto-poll is slow.

- **PDB:** `kubectl -n arunanshu-dev get pdb arunanshu-dev` shows `ALLOWED DISRUPTIONS 1`,
  and `kubectl -n argocd get application <arunanshu-dev app>` Synced/Healthy.
- **cloudflared:** live pod shows `terminationGracePeriodSeconds: 60` and env
  `TUNNEL_GRACE_PERIOD=50s`; pods roll cleanly, `/ready` healthy, tunnel streams stay up
  (`CloudflaredTunnelDead` not firing).
- **vmsingle:** live VMSingle/pod arg shows `-retentionPeriod=28d` (or `.spec.retentionPeriod`),
  pod serving (HTTP 200), no restart. Storage growth tracked over the following weeks stays
  well under 10Gi.
- **tempo:** comment-only change; confirm no manifest/behaviour diff (limit still 1Gi,
  GOMEMLIMIT still 800MiB) and app health unchanged.

## Rollback

Each change is an independent git revert; ArgoCD reconciles back. No data or PVC involved
(retention change only affects future eviction of old parts; lowering it back is safe).

## Follow-ups (out of scope)

- Confirm CF edge micro-caching of arunanshu.dev's HTML/RSC is actually deployed — the
  standing #1 HN-hug survival lever, CF/app-side.
- If the ingress tier is ever suspected as a hug choke point, load-test it (rate window +
  ceilings), don't hunch-tune the poll interval.
