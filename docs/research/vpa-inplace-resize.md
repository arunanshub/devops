# VPA and In-Place Pod Resize

What VPA is, how in-place resize works, why nothing was updating at first, what we fixed, and what we learnt. Read this before touching any VPA config or before adding a new VPA-managed workload.

---

## What VPA does and why we use it

Every pod in Kubernetes has **resource requests** — declarations of how much CPU and memory it needs. The scheduler uses these to decide where to place the pod. If you set them too low, the pod runs on a node without enough headroom and risks being OOM-killed. If you set them too high, that capacity is reserved and unavailable to everything else.

The right numbers are hard to know upfront. Usage changes over time. **Vertical Pod Autoscaler (VPA)** watches how much CPU and memory each pod actually uses, builds a statistical model of that usage, and adjusts the requests to match reality.

We use VPA instead of manually tuning requests because:

- We run several single-replica stateful workloads (Grafana, Prometheus, Tempo, ArgoCD app controller) whose usage drifts over time.
- Horizontal scaling (adding more replicas) is blocked for most of them by RWO PVCs — only one pod can mount the volume at a time.
- VPA is the only practical way to keep requests correctly sized without manual intervention.

---

## VPA's three components

VPA is not one thing. It has three separate components that work independently:

**Recommender.** Continuously queries the metrics server, builds a histogram of CPU and memory usage per container over time, and writes recommendations into `VPA.status.recommendation`. It never touches a running pod — it only writes numbers.

**Updater.** Runs on a loop (roughly every minute). Reads the recommendations. Decides whether the live pod's requests are far enough outside the recommended range to justify an update. If they are, it either patches the pod in-place or evicts it so the admission controller can apply the new values when the pod restarts.

**Admission controller.** A mutating webhook. Every time a pod is created (including after an eviction), it intercepts the pod before it starts and rewrites the resource requests to match VPA's current recommendation. This is what actually gets the numbers into a new pod. It doesn't touch running pods.

**Key point:** If the updater never acts, the admission controller still applies correct resources whenever a pod restarts for any other reason — a crash, a rolling update, a node drain. VPA is not useless if the updater is stuck; it just won't proactively fix things.

---

## Update modes

Each VPA object has an `updateMode`. The relevant ones:

- **`Off`**: Recommender runs and writes recommendations, but nothing is applied. Use this first in production to observe what VPA would do without it doing anything.
- **`Initial`**: Admission controller applies recommendations at pod creation only. No in-place updates, no evictions.
- **`Recreate`**: Updater evicts pods when their requests drift outside the recommended range. Admission controller applies on the new pod.
- **`InPlaceOrRecreate`**: Updater tries to resize the pod **in place** first. Only falls back to eviction if in-place fails.

We use `InPlaceOrRecreate` because eviction means a brief outage on single-replica pods. In-place means no outage.

---

## What "in-place resize" actually means

When VPA resizes a pod in-place, it does **not** delete the pod or restart the container. Instead:

1. The VPA updater sends a `PATCH` request to the Kubernetes API targeting the pod's `/resize` subresource. This updates `spec.containers[].resources` on the live pod object.
2. The kubelet on that node detects the change.
3. The kubelet updates the container's **Linux cgroup** directly — the cgroup is the kernel mechanism that enforces CPU and memory limits on processes. The container process keeps running throughout.
4. The pod's `status.containerStatuses[].allocatedResources` reflects the new values once the kubelet has confirmed the change.

The pod UID stays the same. The container PID stays the same. From the application's perspective, memory headroom just quietly changed. There is no downtime.

---

## resizePolicy: what happens when resources change

Each container has an optional `resizePolicy` field that tells the kubelet how to handle a resource change:

- **`NotRequired`** (the default for both CPU and memory): apply the cgroup change while the container keeps running. No restart.
- **`RestartContainer`**: restart the container after changing the cgroup. Necessary for apps like the JVM that read their memory ceiling once at startup and can't adjust it at runtime.

If you don't set `resizePolicy`, both CPU and memory use `NotRequired` — the safest default, meaning changes happen without any disruption.

**Important:** VPA does not look at `resizePolicy` when deciding whether to apply an update. It simply sends the resize request and lets the kubelet honour whatever policy is set. VPA's job ends at the PATCH; the kubelet handles the mechanics.

---

## The problem we found: everything was stuck

We set `updateMode: InPlaceOrRecreate` on all our VPAs and waited. Nothing happened. The VPA updater logs showed this every minute, for every single-replica pod:

```
"Too few replicas" kind="ReplicaSet" livePods=1 requiredPods=2 globalMinReplicas=2
"Can't in-place update pod, but not falling back to eviction. Waiting for next loop"
```

The VPA updater has a global safety floor: `--min-replicas=2` (the default). The logic is: if you only have one replica and VPA evicts it, the service goes to zero. That would cause downtime, so VPA refuses to act.

This floor applies to **both** eviction **and** in-place updates. Even though in-place doesn't evict the pod and therefore doesn't cause downtime, the implementation checks the same replica count before attempting either path. This is a known implementation gap in VPA (tracked upstream as issue #8980 — the design doc says in-place should bypass this check, but the code doesn't). It was partially fixed in VPA 1.7.0 via a new flag (`--in-place-skip-disruption-budget`).

**The result:** on all our single-replica workloads, VPA had correct recommendations but was applying none of them. Memory requests stayed stale. CPU stayed stale. The admission controller would have applied correct values on the next natural pod restart, but the updater never proactively triggered one.

---

## Why we didn't use `--min-replicas=1` on the updater

The obvious fix is to lower the global floor to 1. We tried this first (adding `--min-replicas=1` to the updater's Helm values). It works, but it's a blunt instrument: it would allow the updater to evict *any* single-replica pod in the cluster, even ones you didn't intend VPA to be that aggressive with.

The better fix is **per-VPA**: set `spec.updatePolicy.minReplicas: 1` directly in each VPA object that manages a single-replica workload. This opts each workload in individually. The global floor stays at 2.

---

## The fix we applied

We added `minReplicas: 1` to each VPA that targets a single-replica workload:

```yaml
spec:
  updatePolicy:
    updateMode: InPlaceOrRecreate
    minReplicas: 1
```

Workloads covered:

| Workload | Namespace | Kind |
|---|---|---|
| Grafana | monitoring | Deployment |
| Prometheus | monitoring | StatefulSet |
| Tempo | monitoring | StatefulSet |
| ArgoCD app controller | argocd | StatefulSet |
| cert-manager cainjector | cert-manager | Deployment |

Traefik was left without `minReplicas: 1` because KEDA keeps it at 2 replicas — the global floor of 2 is already satisfied.

---

## What happened after the fix

The VPA updater logs immediately changed from the stuck message to:

```
"Overriding minReplicas from global to per-VPA value" globalMinReplicas=2 vpaMinReplicas=1 vpa="monitoring/grafana"
```

And Grafana's memory request was updated in-place:

```
Before: requests={cpu: 25m, memory: 384Mi}   restartCount=0
After:  requests={cpu: 25m, memory: ~640Mi}   restartCount=0
```

Zero restarts. Zero evictions. The kubelet updated the cgroup directly. The sidecar containers (`grafana-sc-dashboard`, `grafana-sc-datasources`) were also resized in-place in the same pass.

---

## Why CPU didn't change (and that's fine)

The VPA recommendation for Grafana's CPU was ~25m — the same as the current request. There was nothing to update. The updater only acts when the current request falls outside `[lowerBound, upperBound]` in the recommendation. CPU was already inside that band.

For future reference: if you expect CPU to be resized but it isn't, check the VPA object's `status.recommendation` and compare `lowerBound` and `upperBound` against the pod's current requests. If the current value sits between them, VPA considers it fine and won't act.

---

## How VPA decides when to act

The updater doesn't apply every recommendation immediately. It acts when the pod's current requests fall **outside** the recommendation's `[lowerBound, upperBound]` range, OR when:

- A container had a quick OOM (killed within 10 minutes of starting), OR
- The pod has been running for at least 12 hours and the total request differs from the target by more than 10%.

Outside the recommended range is the most common trigger. This is what fired for Grafana: the memory request (384Mi) was below the lower bound (~560Mi), so the updater acted immediately once `minReplicas=1` unblocked it.

---

## VPA tracks all containers, including sidecars

VPA targets the whole pod, not individual containers. It discovers all containers in the pods it watches and tracks usage for each. Our Grafana deployment has three containers:

- `grafana` — the main Grafana process
- `grafana-sc-dashboard` — sidecar that watches ConfigMaps for dashboards and hot-loads them
- `grafana-sc-datasources` — sidecar that does the same for datasources

VPA tracks and resizes all three. Our VPA policy only sets explicit bounds for the `grafana` container; the sidecars are managed with uncapped defaults (VPA can recommend any value for them within the defaults). Given they're small (~90Mi memory, ~11m CPU) and stable, this is fine.

---

## The QoS class gotcha

Kubernetes assigns each pod a QoS (Quality of Service) class based on its requests and limits:

- **Guaranteed**: requests == limits for all resources on all containers.
- **Burstable**: at least one request or limit is set, but they're not all equal.
- **BestEffort**: no requests or limits set at all.

**VPA cannot change a pod's QoS class.** If a pod starts as BestEffort (no requests), VPA cannot add requests in-place — adding a request would change the class to Burstable, which requires a pod recreate. This will result in eviction even in `InPlaceOrRecreate` mode.

Always set initial `resources.requests` in your pod spec, even if the values are placeholder minimums. This keeps the pod in Burstable class so VPA can adjust in-place.

---

## Things to watch out for when adding a new VPA

1. **Set initial requests.** Even rough ones. BestEffort pods can't be in-place resized.
2. **Add `minReplicas: 1` for single-replica workloads.** Without it, the updater will silently do nothing.
3. **Set `minAllowed`.** Without a floor, VPA can recommend values too small for the application to start.
4. **Set `maxAllowed`.** Without a ceiling, VPA could recommend values that exhaust node capacity.
5. **Start with `updateMode: Off`** in production to see recommendations before they're applied. Promote to `InPlaceOrRecreate` once you're happy with the numbers.
6. **Check the VPA object's status** to confirm the recommendation is being generated: `kubectl get vpa <name> -n <ns>`. If `PROVIDED` is `False`, the recommender hasn't collected enough data yet (it needs a few minutes).

---

## Monitoring

Check VPA updater logs for the pods you care about:

```sh
kubectl -n vpa logs deploy/vpa-updater | grep <namespace>/<podname>
```

The messages to know:

| Log message | Meaning |
|---|---|
| `"Overriding minReplicas from global to per-VPA value"` | per-VPA minReplicas is being applied — good |
| `"Too few replicas"` | minReplicas floor is blocking this pod — add `minReplicas: 1` to the VPA |
| `"Can't in-place update pod, but not falling back to eviction"` | blocked by replica count or disruption budget |
| `"Not updating pod, resource diff too low"` | current request is within recommended range — no action needed |
| `"Overriding minReplicas from global to per-VPA value"` | per-VPA override is working |

To check if a resize happened in-place (vs eviction), look at the pod's `restartCount` before and after. An in-place resize leaves `restartCount` unchanged.

---

## Quick reference

```
VPA updater global min-replicas default:  2
                                          ↑ set minReplicas: 1 per VPA for single-replica workloads

Default resizePolicy (both CPU and memory): NotRequired (no container restart on resize)

VPA acts when:  current request < lowerBound  OR  current request > upperBound
VPA waits when: current request is inside [lowerBound, upperBound]

In-place resize:   kubelet patches cgroup directly, pod stays running, restartCount unchanged
Eviction fallback: pod is deleted, admission controller applies new resources on the new pod
```
