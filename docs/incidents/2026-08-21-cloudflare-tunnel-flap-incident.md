# 2026-08-21 — Cloudflared tunnel flap, full tunnel loss

## Summary

The Cloudflare tunnel lost all connections for a short window. Every public
endpoint returned 520 during that window. The cause was outside the cluster.
The Cloudflare edge reset every tunnel connection on all 3 connector pods in
the same second. The connectors re-registered against other edge colos. No
node failed. No data was lost.

The operator saw the whole site disappear at once. Grafana, ArgoCD, and every
app ride this one tunnel. A full tunnel loss looks like a node loss. The node
was healthy the whole time. "The node went down" means "the tunnel connection
went down".

## Timeline (UTC)

| Time | Event |
|---|---|
| 07:30–07:40 | Reconnect storm 1: 22 then 29 re-registrations in 10 m |
| 10:32–10:35 | Connections drop to 8. Storm 2 starts |
| 10:40 | Total connections reach 0. Full tunnel loss. Pods re-register to AMS |
| 10:47 | All pods drop all connections again |
| 10:50 | Total connections at 6 |
| 10:52–10:55 | More cross-pod drops. Total climbs back through 10 |
| ~11:00 | Connections back to 12 (4 per pod, 3 pods) |

## Root cause

The event is an external Cloudflare edge-path event. It is unattributed.

The evidence for an external edge event:

- All 3 pods lost connections in the same 1–3 second window, several times.
  The pods share nothing except the Cloudflare edge and the tunnel token.
- The logs record `connection with edge closed`. The edge closed the stream.
- The pods re-registered against varied colos: HEL, AMS, LHR, DME.

The event is unattributed. No posted cause explains it:

- Cloudflare posted no maintenance for HEL, AMS, LHR, or DME on this date.
  The only maintenance was MEX (Mexico City). MEX is not on the request path.
- Cloudflare posted no unresolved incident for Tunnel or these colos.
- The 2026-08-13 incident also had 2 unattributed flap events (05:52, 15:01).
  This event matches the same signature.

The origin single-colo dependency is the structural weakness. The cluster runs
in Hetzner Helsinki. IPv4 anycast routes every connector to the nearest
Cloudflare colo. One colo drain therefore drops every connection at once. See
"Why the blast radius is total".

## Ruled out (with evidence)

- **Nodes**: no node went NotReady. No `NodeNotReady` event in 24 h. The Ready
  condition kept its 2026-08-17 timestamp through the event.
- **Node NIC**: zero transmit/receive errors and zero drops on all 3 nodes
  across 10:00–11:00 UTC (`node_network_*_errs_total`, `*_drop_total`).
- **OOM**: no container was OOMKilled. The 2 hccm "Error" pods are leader
  election losers. That is normal for a 2-replica hccm.
- **Origin egress (Hetzner)**: Hetzner posted no HEL1 network incident on this
  date. The re-registrations succeeded within seconds during the zero window.
  Origin-to-edge egress worked the whole time.
- **Network policy (CNP)**: the CNP did not drop edge connections. Every
  observed edge IP was inside the allowed ranges (198.41.192.0/24,
  198.41.200.0/24) on the allowed port (TCP 7844, which http2 uses).
- **Traefik origin port**: the CNP allows egress to Traefik on TCP 8000. The
  Traefik Service is port 80 with target port `web` (container port 8000).
  Cilium enforces the L4 egress rule on the post-DNAT backend port. The rule is
  correct. The `context canceled` proxy errors are a symptom of the edge reset,
  not an origin problem.
- **01:13 UTC node condition flip**: all 3 nodes flipped `NetworkUnavailable`
  at 01:13:23Z. The apiserver stayed up through 01:00–01:30. The nodes stayed
  Ready. This flip is a benign condition re-write. It is not correlated with
  the tunnel event at 10:40.

## Detection result

The alerts worked this time.

- `CloudflaredTunnelReconnectStorm` fired from 07:35 to 11:05. This is the
  correct incident signal.
- `CloudflaredTunnelConnectionsDegraded` went pending 10:35–10:55.
- `CloudflaredTunnelRedundancyLost` went pending at 10:40. It did not reach
  firing. The zero-connection window was shorter than its `for` duration.

Gap: a true full-outage (0 connections) did not page, because the window was
short. `CloudflaredTunnelReconnectStorm` covered the event instead.

## Why the blast radius is total

The tunnel cannot spread across colos on this cluster:

- `--region` accepts only `us`. You cannot pin the tunnel to a chosen region.
- `--edge-ip-version auto`/`6` cannot run here. The cluster is IPv4 only
  (`enable-ipv6: false`, single IPv4 pod CIDR, no pod IPv6 address). cloudflared
  cannot originate IPv6 to reach the IPv6 edge colos.
- More replicas do not help. Every replica uses IPv4 anycast from the same
  location, so every replica anchors to the same nearest colo.

So a single colo drain drops the whole tunnel. This is a property of a
single-location origin behind Cloudflare anycast. It is not fully fixable on
this cluster.

The two IPv6 edge CIDRs in the CNP (2606:4700:a0::/48, 2606:4700:a8::/48) are
dead entries. The IPv4-only cluster can never match them.

## Transport note (http2 vs QUIC)

The connector runs `--protocol http2` since 2026-08-17. QUIC lost all
connections during the 08-17 edge event, so the operator forced http2.

Observation, not a controlled result: today's http2 reconnect gaps were 60 s to
about 4 minutes. The documented QUIC re-registration on 08-13 was about 20 s.
These are different events under different edge conditions. There is no control.

What is proven: neither transport prevents an edge reset. QUIC collapsed on
08-13 and 08-17. http2 reached 0 connections today. Transport choice changes
recovery time, not prevention.

Open question: why did http2 retry the draining path for up to 4 minutes?
`--retries` defaults to 5 with exponential backoff. Do not flip the transport
reactively. A QUIC revert re-opens the 08-17 collapse risk.

## Remediation

1. Keep the current alerts. They fired and caught the event.
2. Consider a shorter `for` on `CloudflaredTunnelRedundancyLost` so a true
   0-connection window pages.
3. Accept the residual risk. A single colo drain drops this tunnel. No
   Cloudflare run parameter available on this IPv4-only cluster prevents it.
4. On the next 520 report, check first:
   - `kubectl logs -n cloudflared -l app=cloudflared --since=24h | grep 'Connection terminated'`
     (same-second drops across all pods = external path event).
   - Cloudflare `scheduled-maintenances.json` AND `incidents.json` (full feeds,
     not only the active/unresolved views).
   - Hetzner status for the HEL1 network.
</content>
</invoke>
