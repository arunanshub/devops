# Cloudflare Tunnel Transport Experiment

This runbook documents the temporary HTTP/2 experiment on the connection between
Cloudflare's network and the cluster's cloudflared connectors. It is an
observation exercise, not a conclusion that QUIC caused the incident.

## Scope

The request path has three independently negotiated legs:

```text
browser -- HTTP/2 or HTTP/3 --> Cloudflare edge
        -- QUIC or HTTP/2 --> cloudflared
        -- HTTP/1.1 --> Traefik and the origin
```

The `--protocol http2` setting changes only the middle leg. It does not disable
browser-facing HTTP/3 and is unrelated to cloudflared's `--http2-origin` option.

The cloudflared binary remains pinned independently in
`kubernetes/components/cloudflared/resources/kustomization.yaml`. During this
experiment it stays on version 2026.5.2 with the existing image digest, so the
connector transport is the only intended variable.

## Incident evidence

On 2026-07-15, authenticated Grafana browsing showed intermittent 6–18 second
static-asset transfers, JavaScript `ChunkLoadError` failures, and a Cloudflare
520 response at 21:07:59 UTC. That 520 did not reach Traefik or Grafana, while
the origin served another request in 118 microseconds at the same second.

The current cloudflared pod logs also record synchronized QUIC failures on
separate replicas:

- 2026-07-12 12:15 UTC: both connectors reported `timeout: no recent network activity`.
- 2026-07-13 04:38 UTC: another QUIC connection failed and re-registered.
- 2026-07-15 13:38 UTC: several connections across both replicas failed; recovery selected new Amsterdam edge addresses.

No corresponding Grafana saturation, Traefik delay, node-interface drop, or
Cilium/WireGuard drop explained the 520. However, visitor-side IPv6 response
body stalls were independently reproduced over both browser HTTP/2 and HTTP/3.
That remains a competing hypothesis and must be recorded during observation.

The evidence justifies isolating the connector transport. It does not prove
that QUIC is the root cause, and the cluster's prior stable operation on QUIC is
one reason to keep the conclusion provisional.

## Experimental setting and attribution

The Deployment temporarily passes the following tunnel run parameter before
`run`:

```yaml
- --protocol
- http2
```

Primary and supporting references:

- [Cloudflare Tunnel run parameters](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/#protocol) define `auto`, `http2`, and `quic`; `auto` normally selects QUIC and can fall back to HTTP/2.
- [Cloudflare Tunnel connectivity prechecks](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/troubleshoot-tunnels/connectivity-prechecks/) document forcing HTTP/2 when testing a failing UDP/QUIC path.
- [cloudflared issue #895](https://github.com/cloudflare/cloudflared/issues/895) contains reports of degraded QUIC response times and improvement after forcing HTTP/2. It is related field evidence, not attribution of this incident.

The pinned 2026.5.2 binary accepts `cloudflared tunnel --protocol http2 run`.
Its generated help omits this hidden option, so both the upstream documentation
and a non-mutating parser check were used before changing the manifest.

## Activation checks

Let ArgoCD reconcile the committed manifest; do not live-patch the Deployment.
Then confirm the rollout and registered protocol:

```bash
kubectl rollout status deployment/cloudflared -n cloudflared --timeout=5m
kubectl get pods -n cloudflared -l app=cloudflared -o wide
kubectl logs -n cloudflared -l app=cloudflared --since=10m \
  | rg 'Registered tunnel connection|"protocol":"http2"|error|warn'
```

Both replicas must be Ready. Each new registration must report
`"protocol":"http2"`; any QUIC registration means the override is not active
on that connector.

On cloudflared 2026.5.2, the asynchronous connectivity precheck can later log
`cloudflared will use 'quic' as primary protocol` and
`"suggested_protocol":"quic"` even while the explicit HTTP/2 override is active.
That message reports the protocol the network precheck would recommend because
UDP connectivity succeeded; it is not the connector's selected transport. Use
`Initial protocol http2` and the per-connection
`"protocol":"http2"` registration fields as the authoritative checks.

## Observation window

Observe for at least 60 minutes while reproducing the original authenticated
Grafana workload from more than one browser:

1. Use cold/static chunk loads rather than relying only on warm navigation.
2. Record visitor IPv4 versus IPv6 for each slow or failed request.
3. Capture static-asset transfer latency, especially individual multi-second
   stalls and p95/p99 if enough samples exist.
4. Record Cloudflare 5xx responses, particularly 520, including timestamp and
   Ray ID when available.
5. Correlate cloudflared stream/reconnect errors with Traefik and Grafana origin
   latency.

Useful connector checks:

```bash
kubectl logs -n cloudflared -l app=cloudflared --since=1h --prefix \
  | rg -i 'error|warn|timeout|connection terminated|registered tunnel'
kubectl get pods -n cloudflared -l app=cloudflared \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount'
```

Relevant Grafana/Prometheus queries include:

```promql
min_over_time(cloudflared_tunnel_ha_connections[5m])
increase(cloudflared_tunnel_request_errors[5m])
increase(cloudflared_proxy_connect_stream_errors[5m])
```

## Interpreting the result

The result supports further investigation of the connector QUIC path only when
equivalent Grafana browsing stops showing the previous multi-second tail stalls
and 520 responses while workload and origin latency remain comparable.

The result is inconclusive when the original symptom does not recur under
either transport, the workload is not comparable, or visitor IP-family data is
missing. Absence of failure during one quiet hour is not proof of a fix.

The result weakens the connector-QUIC hypothesis when equivalent stalls persist
over HTTP/2, especially when they correlate with visitor IPv6 while the tunnel
and origin remain healthy.

Rollback immediately if connector readiness or capacity drops, tunnel errors
increase, or user-visible latency worsens.

## Rollback

The default outcome after the observation window is to restore automatic
selection. Remove these arguments from the Deployment:

```yaml
- --protocol
- http2
```

Commit and push the rollback through GitOps, wait for both replicas, and verify
that new registrations report `"protocol":"quic"`. Keeping HTTP/2 beyond the
experiment requires a separate evidence-backed decision.
