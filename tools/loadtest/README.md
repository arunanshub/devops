# arunanshu-dev load test

## Recommended: run inside Kubernetes

Run a 30-second GET smoke test:

```bash
tools/loadtest/run-in-cluster.sh --smoke --yes
```

Run the six-minute GET capacity profile:

```bash
tools/loadtest/run-in-cluster.sh --yes
```

The launcher creates a temporary ConfigMap and Job in `arunanshu-dev`, using the pinned official `grafana/k6:2.1.0` image. Test traffic stays inside the cluster:

```text
k6 Job -> Traefik ClusterIP -> HTTPRoute -> application pods
```

The launcher waits for the Job, prints HPA status during the run, returns the k6 container exit status, and removes both temporary resources. A capacity run also fails unless KEDA exposes its metric and scales above the starting replica count. Pass `--keep` to preserve resources from either a successful or failed run. Pass `--dry-run` to print the generated resources without creating them.

This path bypasses Cloudflare and `kubectl port-forward` while preserving Traefik metrics used by KEDA. It downloads the real GET response body, so page size, compression, server work, and cluster networking contribute to the result. The generator requests 250m CPU and 128 MiB memory; account for that small cluster-side cost when interpreting node saturation.

## Local diagnostic

You can still run the JavaScript locally for script development:

```bash
k6 run tools/loadtest/arunanshu-dev.js
```

The script defaults to HEAD locally. HEAD measures handler and proxy residence time, not representative GET service time or full-page capacity.

The profile lasts six minutes. After the first 30 seconds, it aborts when the cumulative HTTP failure rate exceeds 5%. It fails if k6 drops any scheduled iterations or cumulative p95 latency exceeds 500 ms. Press Ctrl-C if pods restart repeatedly or nodes report pressure.

The optional `TARGET_URL` environment variable changes the local port or path. Keep the `Host` header in the script so the HTTPRoute continues to match.
