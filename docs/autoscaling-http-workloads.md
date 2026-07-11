# Autoscaling HTTP workloads with Little's Law

Use this guide when you need to choose a horizontal scaling signal and set its target. The short version is:

1. Hold the replica count steady.
2. Send representative traffic through the real ingress path.
3. Increase request rate in plateaus.
4. Find the last plateau that meets the service objective.
5. Calculate average concurrency per pod.
6. Configure 25–40% headroom and run a second test with autoscaling enabled.

For `arunanshu-dev`, the first useful concurrency target is `0.4` per replica.

## Tutorial: measure one workload

### 1. Choose representative requests

Use the same methods, routes, bodies, authentication, cache behavior, and response sizes that users generate. A route mix is better than one convenient endpoint when routes have different costs.

Run the generator outside the target workload's resource pool. Good locations include a separate machine on the private network or a dedicated load-generator node. An in-cluster pod also works when node affinity and resource limits prevent it from competing with the application.

Send traffic through the component that exports the scaling metric. For this cluster, use Traefik and the real `HTTPRoute`, while bypassing Cloudflare.

Avoid `kubectl port-forward` for a full-body capacity result. The API-server tunnel can become the measured bottleneck.

### 2. Fix capacity during the measurement

Use a fixed replica count for the capacity test. This makes the per-pod result interpretable. Disable or pause horizontal scaling for this phase, but leave the application configuration unchanged.

Choose a replica count that still exposes per-pod pressure. One or two replicas usually suffice. Do not use a single replica when losing it would break an important environment.

### 3. Use an open workload model

Use k6's `ramping-arrival-rate` executor. An arrival-rate test keeps offering requests when latency rises. A fixed-VU test slows its request generation as responses slow down and can hide saturation.

Hold each plateau long enough for latency, resource use, garbage collection, caches, and downstream pools to settle. Two to five minutes per plateau is a sound production test. Shorter exploratory tests can identify the useful range first.

Record at least:

- Offered and successful requests per second.
- Mean, p95, and p99 response duration.
- Errors, timeouts, and dropped iterations.
- Ready replicas and restarts.
- Per-pod CPU and memory.
- Queue depth or in-flight requests when available.
- Downstream pool saturation, such as database connections.

### 4. Find the knee

The knee is the last stable plateau before one or more signals deteriorate:

- p95 or p99 latency rises faster than request rate.
- Errors or timeouts exceed the service objective.
- A queue grows throughout the plateau.
- CPU stays saturated.
- Memory approaches the limit or pods restart.
- A downstream dependency reaches its safe limit.

Use the last healthy plateau, not the first failing one.

### 5. Calculate the concurrency target

Little's Law relates average concurrency `L`, throughput `λ`, and mean residence time `W`:

```text
L = λ × W
```

For a replicated HTTP service:

```text
healthy concurrency per pod =
  successful RPS × mean server duration in seconds ÷ ready replicas

autoscaling target =
  healthy concurrency per pod × headroom factor
```

Start with a headroom factor between `0.60` and `0.75`. Use more headroom when traffic is bursty, startup is slow, metrics arrive late, or downstream failure is expensive.

Example:

```text
200 RPS × 0.040 seconds ÷ 2 pods = 4 concurrent requests per pod
4 × 0.70 = 2.8 target concurrency per pod
```

Little's Law uses the mean duration. Use p95 and p99 to decide whether a plateau is healthy, but do not substitute a percentile into the equation.

### 6. Validate autoscaling

Restore autoscaling and repeat a ramp that crosses the proposed target. Confirm:

- The metric becomes active before latency breaks the objective.
- Desired replicas rise as expected.
- New pods become ready soon enough to absorb the burst.
- Scale-down does not remove capacity between nearby bursts.
- The metric returns to baseline after traffic stops.

Treat the first result as a starting value. Re-test after runtime, route mix, caching, resource requests, limits, or downstream dependencies change.

## How to choose the scaling signals

### Concurrency or queue depth

Use concurrency for request-serving workloads whose cost tracks active work. Use queue depth for workers and asynchronous systems. These signals expose pressure before CPU necessarily reaches saturation.

A proxy-derived duration metric can estimate average concurrency:

```promql
sum(rate(traefik_router_request_duration_seconds_sum{router=~"my-router.*"}[1m]))
```

The rate of accumulated request-seconds has units of concurrent requests. Verify the metric's boundaries for the proxy version and protocol. A metric that ends after upstream headers, for example, will not represent slow response-body delivery.

### CPU

CPU is a useful secondary signal for compute-bound services. CPU utilization HPA divides usage by CPU requests, so its behavior depends on accurate, stable requests. A VPA that changes CPU requests also changes the HPA's effective scaling threshold.

If VPA controls CPU requests, prefer concurrency for HPA and use CPU as an alert. Another option is to run VPA in recommendation-only mode, set stable requests from its observations, and then add CPU utilization as a second HPA metric.

### Memory

Memory is usually a safety constraint rather than the primary horizontal signal. Managed runtimes retain heaps, caches remain warm, and usage may not fall when traffic stops. Horizontal scaling cannot reliably prevent a sudden OOM.

Set a rational memory request and limit, alert before the limit, and investigate growth. Add memory scaling only when measurements show a repeatable relationship between traffic per pod and reclaimable memory.

### Multiple signals

Kubernetes HPA calculates a replica recommendation for each metric and selects the largest recommendation. A common mature setup combines concurrency or queue depth with CPU. Memory alerts protect the process while VPA recommendations help size requests.

## Reference: interpreting KEDA's target

KEDA's Prometheus scaler uses an `AverageValue` target for this workload. When the query returns total concurrency across the deployment:

```text
desired replicas ≈ total concurrency ÷ target concurrency per pod
```

For a target of `0.4`:

```text
total concurrency 0.8  -> about 2 replicas
total concurrency 1.2  -> about 3 replicas
total concurrency 2.0  -> about 5 replicas
total concurrency 3.2  -> about 8 replicas
```

Metric timing matters. Traefik is scraped every 30 seconds in this cluster, while KEDA polls every 15 seconds. The one-minute PromQL range provides enough samples but smooths bursts. Fast scale-up behavior and spare minimum replicas cover part of that delay. Shortening the range below two scrape intervals produces unreliable rates.

## Case study: arunanshu-dev on 2026-07-11

The test sent traffic through a local Traefik port-forward with `Host: arunanshu.dev`, targeting:

```text
/blog/next-server-actions-client-side-data-fetching
```

### Full-body GET diagnostic

The page transferred about 333 KB per request. A short fixed-VU run produced:

- About 32 RPS.
- Zero errors.
- Mean client duration of 311 ms.
- p95 client duration of 489 ms.

The ramp later crossed 713 ms p95 while pod CPU remained low. The port-forward moved hundreds of megabytes and became the dominant constraint. This run does not establish full-page origin capacity.

### HEAD request-handling test

HEAD removed response-body transfer while preserving Traefik routing and metrics. The six-minute open-loop test produced:

- 46,274 successful requests.
- Zero errors and zero dropped iterations.
- Peak one-minute throughput of about 263 RPS.
- Overall mean client duration of 247 ms.
- Overall p95 client duration of 275 ms.
- Peak Traefik concurrency of `1.093` across two replicas.
- Measured peak concurrency of about `0.547` per replica.
- Peak observed CPU around 450m per pod.
- Peak observed memory of 246 MiB against the then-current 256 MiB limit.
- No restarts or readiness failures.

The old KEDA target of `10` required far more concurrency than this static workload generated. KEDA stayed at two replicas throughout the test. The run ended at its planned ceiling without finding the unhealthy side of the knee, so `0.547` is the highest observed healthy HEAD concurrency rather than measured capacity.

Choosing a provisional trigger 27% below that observation gives:

```text
0.547 × 0.73 ≈ 0.4 concurrent requests per pod
```

The repository now uses `0.4` as the provisional target. This margin is not proven capacity headroom because the test did not cross the knee. The configuration also allows immediate scale-up and delays scale-down for five minutes. A fixed-replica, real-GET test over a private path must find the knee and confirm the value because HEAD does not measure compression, response transfer, or slow-client backpressure.

### VPA decision

The live VPA recommended about `15m` CPU and `335 MiB` memory after the test. Its policy permits up to one CPU and 512 MiB. The test reached 246 MiB against the old declarative 256 MiB limit, so the repository now sets a 384 MiB baseline limit. This protects the pod when VPA admission or updates lag while leaving VPA room to adjust within its policy.

Do not add CPU-utilization scaling while VPA controls CPU requests. A 15m request would make ordinary CPU use appear several hundred percent utilized and drive premature horizontal scaling. Reconsider CPU HPA after collecting a longer recommendation history and choosing a stable CPU request.

## Checklist

Before accepting a threshold, verify:

- [ ] Traffic uses representative methods, routes, bodies, and cache behavior.
- [ ] The load generator does not compete with the target pods.
- [ ] The test crosses the healthy-to-unhealthy knee.
- [ ] Little's Law uses successful throughput and mean server duration.
- [ ] The threshold includes 25–40% headroom.
- [ ] Autoscaling activates in a second test.
- [ ] Pod startup fits within the traffic burst budget.
- [ ] CPU requests remain stable if CPU utilization drives HPA.
- [ ] Memory has separate limits and alerts.
- [ ] The team repeats the test after material workload changes.

## Further reading

- [Kubernetes HPA walkthrough](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/)
- [Kubernetes vertical pod autoscaling](https://kubernetes.io/docs/concepts/workloads/autoscaling/vertical-pod-autoscale/)
- [KEDA ScaledObject specification](https://keda.sh/docs/2.21/reference/scaledobject-spec/)
- [k6 arrival-rate VU allocation](https://grafana.com/docs/k6/latest/using-k6/scenarios/concepts/arrival-rate-vu-allocation/)
- [Traefik metrics overview](https://doc.traefik.io/traefik/observability/metrics/overview/)
