# arunanshu-dev load test

Forward the Traefik Service so requests bypass Cloudflare but still produce the metrics used by KEDA:

```bash
kubectl --kubeconfig infra/kubeconfig.yaml \
  -n traefik port-forward service/traefik 18080:80
```

In another terminal, verify that Traefik selects the route:

```bash
curl -fsS -o /dev/null -w '%{http_code}\n' \
  -H 'Host: arunanshu.dev' \
  http://127.0.0.1:18080/blog/next-server-actions-client-side-data-fetching
```

Run the test from the repository root:

```bash
k6 run tools/loadtest/arunanshu-dev.js
```

The script uses `HEAD` by default. This avoids measuring the Kubernetes port-forward's throughput while retaining Traefik routing and request-duration metrics. HEAD measures HEAD handler and proxy residence time, not representative GET service time or full-page capacity. Use `METHOD=GET` from a private-network generator for a production capacity result.

The profile lasts six minutes. After the first 30 seconds, it aborts when the cumulative HTTP failure rate exceeds 5%. It reports a failed threshold when cumulative p95 latency exceeds 500 ms, but port-forward latency alone does not stop the run. Press Ctrl-C if pods restart repeatedly or nodes report pressure.

The optional `TARGET_URL` environment variable changes the local port or path. Keep the `Host` header in the script so the HTTPRoute continues to match.
