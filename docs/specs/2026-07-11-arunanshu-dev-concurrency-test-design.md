# arunanshu-dev concurrency test design

## Goal

Measure the concurrency that each `arunanshu-dev` replica can serve before latency or errors deteriorate, validate that KEDA scales from the observed Traefik concurrency, and recommend a safe Little's Law threshold.

## Scope

The test will exercise the live `arunanshu-dev` deployment for no more than ten minutes. Increased load may degrade or restart the application pods. The test will not change the deployment, KEDA, VPA, or routing configuration.

The target route is:

```text
/blog/next-server-actions-client-side-data-fetching
```

All requests are public and read-only.

## Request path

k6 will run on the operator's workstation and connect to a local port-forward for the Traefik Service. Each request will carry `Host: arunanshu.dev`, allowing the Gateway API HTTPRoute to select the application backend.

```text
k6 -> local port-forward -> Traefik -> HTTPRoute -> Service -> application pods
```

This path bypasses Cloudflare and preserves the Traefik duration metrics consumed by KEDA. A direct port-forward to the application Service would bypass those metrics and cannot validate autoscaling behavior.

## Load profile

k6 will use an open-loop, ramping arrival-rate scenario. The run will start at a low request rate and advance through short plateaus until one of these conditions occurs:

- KEDA reaches its configured maximum of eight replicas.
- The application crosses a stop condition.
- The planned run time expires.

The operator may adjust later stages during the run if early measurements show that the preset rates are too low or too high. The complete run will stay within ten minutes.

## Measurements

The run will collect or observe:

- Request rate, successful request rate, mean latency, p95 latency, p99 latency, and error rate from k6.
- Traefik's request-duration sum and count rates.
- KEDA trigger activity, HPA desired replicas, and actual ready replicas.
- Per-pod CPU and memory usage, pod readiness, and restarts.
- Node resource pressure when available.

The Traefik query already configured in the ScaledObject estimates average in-flight requests:

```promql
sum(rate(traefik_router_request_duration_seconds_sum{router=~"httproute-arunanshu-dev.*"}[1m]))
```

The estimate follows Little's Law: average concurrency equals throughput multiplied by mean residence time.

## Health and stop conditions

The preferred operating envelope is:

- p95 latency below 300 ms.
- Request error rate below 0.5%.

The acceptable boundary is p95 latency below 500 ms and request errors below 1%.

The operator will stop the run if any of these conditions occurs:

- Sustained request errors exceed 5%.
- Application pods repeatedly restart or fail readiness.
- Nodes report serious CPU, memory, disk, or PID pressure.
- Latency grows without reaching a stable plateau.
- The load generator cannot sustain the configured arrival rate and increasing k6 capacity does not correct it.

## Analysis

For each stable plateau, the analysis will calculate:

```text
observed concurrency = successful requests per second * mean response time in seconds
```

The last plateau within the acceptable boundary defines measured healthy capacity. Dividing its observed concurrency by the number of ready replicas gives the measured per-replica capacity.

The recommended KEDA threshold will start near 70% of measured healthy per-replica concurrency. The final report will also assess:

- Whether the current threshold of 10 is safe.
- Whether KEDA scales soon enough to protect latency.
- Whether the one-minute Prometheus range delays scale-up.
- Whether HPA scale-up behavior needs tuning.

The first run will produce recommendations only. Configuration changes require a separate review.

## Artifacts and cleanup

Implementation will add a reusable k6 script and supporting run instructions in the repository. The operator will terminate all port-forward and monitoring processes after the run. The test will not leave temporary workloads in the cluster.
