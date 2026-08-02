---
name: cloudflared-forced-http2-live-2026-08
description: cloudflared connector-to-edge protocol is forced to http2 (not quic/auto) in production as of 2026-07-31, unrelated to and outlasting the original Grafana-520 experiment scope
metadata:
  type: project
---

`kubernetes/components/cloudflared/resources/deployment.yaml` currently forces `--protocol http2`
on the cloudflared connector (Cloudflare edge <-> cloudflared leg only; browser-facing HTTP/3 and
cloudflared->Traefik legs are unaffected). Confirmed live via pod logs 2026-08-02: both replicas
report `"will use 'http2' as primary protocol"`.

Timeline (`git log -- kubernetes/components/cloudflared/resources/deployment.yaml`):
- 2026-07-16 (`5037471`): forced http2 as a time-boxed experiment to isolate a Grafana-only
  incident (6-18s static asset stalls + one CF 520, correlated with synchronized QUIC
  "no recent network activity" timeouts). Runbook: `docs/cloudflare-tunnel-transport.md`.
  Explicit default-after-window was `auto`; keeping http2 required "a separate
  evidence-backed decision."
- 2026-07-31 (`2ccbc6f` then `faed7da`, same day): briefly reverted to commented-out (auto/quic),
  then re-enabled http2 — with no accompanying doc update, no new incident evidence cited, no
  observation-window record. The runbook was never updated to reflect a permanent decision.

**Why this matters:** this tunnel is shared by every app behind it (arunanshu.dev, Grafana,
ArgoCD, Headlamp, Hubble — see [[cloudflared-wildcard-routing]] in main project memory). Forcing
HTTP/2 instead of QUIC on a long-haul, high-RTT leg (origin anchors near Hetzner EU; visitors
observed from SIN edge) reintroduces TCP head-of-line blocking and a full TCP+TLS handshake cost
instead of QUIC's 0-RTT/connection migration — exactly the kind of leg where QUIC's advantages
matter most. This was flagged as a concrete, evidence-backed candidate contributing to the
570-1200ms India TTFB investigated 2026-08-02, though it was never isolated as sole cause (the
larger, likely irreducible component is SIN<->EU physical RTT for any request that Cloudflare
cannot serve from cache, e.g. POST/server actions).

**How to apply:** if asked to investigate ingress latency again, check whether this flag is still
forced and whether it's still undocumented as permanent. If revisiting, the falsifiable test is:
revert to `auto`, observe cloudflared logs for `"protocol":"quic"` registration + tunnel error
rate, and compare uncached-GET/POST TTFB from a SIN or similar high-RTT vantage point before/after.
Do not apply/restart/revert anything without explicit user request — this note is diagnostic only.
