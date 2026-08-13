# 2026-08-13 — Intermittent 520s on all public endpoints

## Summary

All `*.arunanshu.dev` endpoints returned intermittent 520 errors. The cause
was outside the cluster. Cloudflare ran scheduled maintenance on the HEL
(Helsinki) colo. The drain dropped every QUIC tunnel connection on all
cloudflared pods in the same second, three times. Each drop caused about
20 seconds of 520s while cloudflared re-registered. No data was lost. No
alert fired. Total user-visible impact: roughly 2 minutes, spread over the
day as short bursts.

## Timeline (UTC)

| Time | Event |
|---|---|
| 08-12 23:00 | Cloudflare HEL maintenance window opens |
| 08-13 00:50 | Drop event 1: 12 → 11 connections |
| 08-13 01:20 | Drop event 2: 12 → 6 connections (worst) |
| 08-13 01:59 | Drop event 3: 12 → 9 connections |
| 08-13 04:00 | HEL maintenance window closes |
| 08-13 05:52 | Drop event 4: 12 → 8 connections (unattributed) |
| 08-13 15:01 | Drop event 5: ~6 connections reset (unattributed) |
| 08-13 ~15:50 | User reports 520s. Investigation starts |

## Root cause

Cloudflare posted the HEL maintenance in `scheduled-maintenances.json`,
not in `incidents.json`. The notice promises only "a slight increase in
latency". For a tunnel origin behind that colo, the real effect is
connection resets. Every anycast dial from a Helsinki origin enters
Cloudflare through the HEL PoP. One colo drain therefore kills all
connections in the same second, on every pod. Events 4 and 5 remain
unattributed. They match the same external-path signature.

QUIC amplified each event. A brief loss window makes QUIC tear down and
re-register (~20 s). TCP stalls and resumes. The 520s lasted as long as
the re-registrations.

## Ruled out (with evidence)

- Apps and Traefik: served 200s all day; in-cluster probes < 10 ms.
- Kubernetes: zero restarts, zero warning events, all nodes Ready.
- Cilium: zero Hubble drops for the whole day.
- Nodes: zero NIC errors, zero UDP buffer errors, conntrack at 1%.
- Client side: a 520 is created between the CF edge and the origin.

## Detection gap

The only tunnel alert (`CloudflaredTunnelRedundancyLost`) needs a
sustained drop below 4 connections. The events lasted ~20-40 s and never
went that low. The 30 s scrape interval missed event 5 completely. The
register counter is the only metric that survives short events.

## Remediation (this commit)

1. `CloudflaredTunnelConnectionsDegraded`: connection total below 4 per
   ready replica for 10 m.
2. `CloudflaredTunnelReconnectStorm`: more than 4 re-registrations in
   30 m with no pod younger than 30 m. A replay at event 4 fires.
3. Transport split: 2 QUIC replicas + 1 http2 (TCP) replica on the same
   tunnel token. See `docs/cloudflare-tunnel-transport.md`.

## Follow-up

- **2026-08-18 00:00-06:00 UTC: Cloudflare AMS maintenance.** The tunnels
  anchor in Amsterdam now. Expect a repeat. This window tests whether the
  http2 connections survive a drain that QUIC does not.
- On future 520 reports, check two things first:
  `kubectl logs -n cloudflared -l app=cloudflared --since=24h | grep 'Connection terminated'`
  (same-second drops across pods = external path) and the Cloudflare
  `scheduled-maintenances.json` feed, not only `incidents.json`.
