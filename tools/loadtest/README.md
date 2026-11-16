# arunanshu-dev load test

k6 runs as a Job inside the cluster against the Traefik ClusterIP:

```text
k6 Job -> Traefik ClusterIP -> HTTPRoute -> application pods
```

This bypasses Cloudflare and `kubectl port-forward`, but still exercises the
Traefik metrics that KEDA scales on. It downloads the real GET body. The
generator requests 250m CPU and 128 MiB; count that when reading node
saturation.

| Profile | Path | Shape |
|---|---|---|
| smoke | `smoke/` | 10 req/s for 30 s |
| capacity | `capacity/` | ramps 10 → 300 req/s over 6 min, aborts above 5 % failures |

## Run

```bash
kubectl create -k tools/loadtest/smoke        # or tools/loadtest/capacity
kubectl -n arunanshu-dev logs -f job/arunanshu-dev-k6
kubectl -n arunanshu-dev delete -k tools/loadtest/smoke
```

Watch scaling in a second terminal while it runs:

```bash
kubectl -n arunanshu-dev get hpa keda-hpa-arunanshu-dev -w
```

A capacity run is a pass when k6 exits 0 (thresholds: no dropped iterations,
p95 < 500 ms, < 5 % failures) **and** the HPA scaled above its starting
replica count. Check the ScaledObject is Ready and not in Fallback first:
`kubectl -n arunanshu-dev get scaledobject arunanshu-dev`.

The Job is removed automatically one hour after it finishes; delete it
earlier to start another run.

## Local diagnostic

```bash
k6 run tools/loadtest/capacity/arunanshu-dev.js
```

Locally the script defaults to HEAD, which measures handler and proxy time,
not full-page capacity. `TARGET_URL` changes the port or path; keep the
`Host` header in the script so the HTTPRoute still matches.
