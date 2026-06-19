# Cluster CPU/Latency Perf Scan (2026-06-19)

Spiritual continuation of `docs/2026-06-17-memory-perf-scan.md`. That scan's lever was
**RAM reduction for reboot headroom**. This one targets **traefik, cloudflared, k3s and the
other naturally hot/latency-sensitive paths** ("must be fast"). Same invariants: reboot-safe
(1 node drains, 2 survive — must not block kured drain or drop ingress), **zero observability
loss**, simplest solution, **no overengineering**, prefer GitOps-reversible.

## Method note — the CPU premise collapsed (read this first)

Before any deep dive, we anchored on **live CPU/throttling data** (the lesson from the memory
scan's own "Method note": don't tune the wrong axis). The result reframes the whole exercise:

| Signal (live, 2026-06-19) | Value | Implication |
|---|---|---|
| CFS throttling, whole cluster (`container_cpu_cfs_throttled_periods_total`) | **zero rows** | Nothing is CPU-throttled, anywhere |
| Node CPU utilization | **10–14%** | Cluster is CPU-idle |
| Total CPU requested vs allocatable | **1.93 / 12 cores (16%)** | Fits on 2 nodes trivially → already reboot-safe on CPU |
| traefik / cloudflared CPU | not in top-20 / ~8 millicores | Negligible |
| Busiest pods (cores): vmsingle 0.30, argocd-app-ctlr 0.12, hubble-ui 0.16, vmagent 0.14, cilium ~0.12 ea | — | Even the "busiest" are fractions of a core |

**There is no CPU to reclaim.** Unlike the RAM scan (which found 400–700Mi of real garbage),
this round has **no footprint win**. So the honest deliverable is *not* "cut CPU" — it is:
**(1)** protect/cap request-path **latency** (latency is an invariant, not a target to trade),
**(2)** fix genuine config-correctness gaps, and **(3)** point at the *actual* user-facing
latency lever, which prior diagnosis already pinned at the **Cloudflare edge / app prefetch**,
not in-cluster CPU.

A 4-agent Sonnet fleet (traefik / cloudflared / k3s+LB / CF-edge-cache) dug each path against
live config + current upstream docs (context7 + exa). Findings below; the genuinely-actionable
set is small and honest.

## Reversibility classes (this round is NOT uniform — unlike the RAM scan)

- **gitops** — ArgoCD/Helm values or kustomize: revert a line, ArgoCD self-heals. Safe.
- **tofu** — OpenTofu `apply` against Cloudflare/Hetzner LB: reversible, no node touch.
- **node-reprovision** — k3s server-args / cloud-init: requires replacing a node *and* risks the
  delicate Cilium MTU/WireGuard datapath (path MTU 1305, auto-upgrading v1.20.0-pre.3).
  **Tiered LOW** — same posture the RAM scan took toward Cilium.
- **app-side** — lives in the `arunanshu-dev` app repo, not this infra repo.

---

## RANKED — by confidence

> **Corrected after adversarial SRE review + live verification against cloudflared 2026.6.0
> and the traefik chart (40.3.0).** Two original proposals were dropped (crash-loop / non-existent
> flag) and three had wrong key-paths that Helm/TF would *silently* accept while no-op-ing the
> change (same trap as `helm-null-override-deletes-chart-default`). **Every values/cache change
> below MUST be confirmed with `helm template` / `tofu plan` showing the key actually lands** before
> ArgoCD/tofu apply — "Synced"/"no error" ≠ "took effect". Numbers retained as IDs; #1 and #9 are
> now in REJECTED.

### Tier A — do now (gitops/tofu-reversible, zero-to-trivial risk)

| # | Change | File | Effect | Win | Why safe |
|---|--------|------|--------|-----|----------|
| 2 | **cloudflared: `terminationGracePeriodSeconds: 60` + env `TUNNEL_GRACE_PERIOD=50s`** | `components/cloudflared/resources/deployment.yaml` (pod spec + env) | k8s default grace (30s) == cloudflared `--grace-period` default (30s, verified `[$TUNNEL_GRACE_PERIOD]`) → SIGKILL races cloudflared's own drain; in-flight requests dropped on rollout. Pod-grace 60 + cloudflared-grace 50 keeps a 10s clearance so the 1:1 race can't re-emerge if cloudflared bumps its default. | correctness ↑ (zero dropped requests on drain) | Pure headroom; kured 5.12.1 honors pod terminationGracePeriod (drainGracePeriod=-1), so it waits the full 60s within a drain. cloudflared is sole egress → directly protects the reboot invariant. Now a standalone change (see dropped #1). |
| 3 | **traefik: `sampleRate: 0.1` inside the existing `tracing:` block** | `base/platform/traefik/values.yaml` (existing `tracing:`, ~L56 — verified no `sampleRate` set today) | Chart default = 100% sampling → every request serialized + OTLP-posted to Tempo:4318 | ~0 now, real CPU/Tempo-write saving under KEDA scale-out | Traces still flow at 10%; Tempo retention unaffected. Confirm via `tempo_distributor_spans_received_total` dropping ~90%. |
| 4 | **traefik: `deployment.lifecycle.preStop.sleep.seconds: 5`** (integer, NOT `sleep: 5s`) | `base/platform/traefik/values.yaml` | Closes the ~1–2s window where the Service endpoint is removed *after* SIGTERM, causing resets on every rollout (KEDA min2/max5 → rollouts happen) | eliminates rolling-update 502s | No steady-state effect; adds 5s per pod to a rollout. k8s `sleep` handler takes `{seconds:N}`, not a duration string — wrong shape silently breaks. |
| 5 | **CF: explicit `/_next/static/` cache rule for apex `arunanshu.dev`** | `infra/cloudflare_cache.tf` (add rule) | Guarantees content-hashed Next.js bundles are edge-cached + gives explicit edge-TTL control (apex has no ZT-cookie gate, but the rule makes it robust) | first-visit static-bundle load ↓; Tiered-Cache upper tier warms | Files are content-hashed (incl. `?dpl=<buildId>`, respected in CF cache key) → stale-serve impossible. No RSC. |
| 6 | **CF: Grafana `/public/build/` edge TTL 7d→30d + add `browser_ttl` 1d** | `infra/cloudflare_cache.tf:47` (+ `action_parameters`) | Longer edge-hit window + stops browser re-validating hashed bundles every session | repeat Grafana cold-load ↓ (~200–800ms saved on browser round-trip) | Content-addressed paths; file comment already suggests the TTL bump. **Check**: confirm the pinned `cloudflare` TF provider supports `browser_ttl` under `action_parameters` (relatively recent field) — `tofu plan` must show it land. |
| 7 | **Hetzner API LB health-check: `interval 15→10`, `timeout 10→5` (retries 3)** | `infra/lb.tf` health_check | Worst-case dead-CP detection `(retries−1)×interval + timeout`: **40s → 25s**. (The aggressive 5/3/3 = 13s option is *not* recommended — see risk.) | CP-failover tail ↓ ~15s | `tofu apply`, no node touch. **Trade-off (was understated in v1):** a transient API blip (etcd leader election can take 5–10s on 3 nodes, or a CP restart mid-rollout) can trip removal; 10/5/3 stays above typical election time, 5/3/3 does not. Removing 1 of 3 CPs is fine, but removal *plus* a simultaneous kured drain = single CP. Gentler interval keeps HA margin. |

### Tier B — one check each, then safe

| # | Change | File | The check |
|---|--------|------|-----------|
| 8 | **traefik: `ports.websecure.transport.respondingTimeouts.writeTimeout: 60s`** (note the `transport.` level — the shallower path silently no-ops) | `base/platform/traefik/values.yaml` | Chart default writeTimeout = **infinite**; a stalled client/backend pins a connection. **Premise is UNVERIFIED** — confirm the live `traefik_service_request_duration_seconds` p99 for the grafana service is actually pinned at the histogram top bucket (not a real slow backend) before assuming this helps. Then confirm `grafana.ini [dataproxy] timeout` (30s) < 60s. **Risk**: a 60s write cap can cut legit long Grafana responses (live-tail/Loki stream/long query) → 504. Apply only if the ceiling claim holds AND no long-stream panels rely on >60s writes. `helm template` must show the key under `transport.respondingTimeouts`. |

### Highest-value lever — but APP-SIDE (not this repo)

- **Next.js `<Link prefetch={false}>` on top-nav links** (arunanshu-dev app repo). The dominant
  user-facing latency multiplier is the **RSC prefetch storm**: every `<Link>` hover/viewport-enter
  fires a `?_rsc=` request, each an **uncached India→SIN→EU round-trip** (origin tunnel is
  EU-anchored). Turning off speculative prefetch on the nav collapses N uncached trips/page into
  1 on-demand trip — a 3–5s perceived-slowness → single ~200–400ms navigation. **No CF cache rule
  can substitute safely** (see REJECTED #R7). This is the single biggest win in the whole scan and
  it is not in this infra repo — flag to the app.

### node-reprovision tier — LOW (defer; same posture as Cilium in the RAM scan)

Each requires replacing a node and risks the MTU/WireGuard datapath. None is worth that on its own;
fold in *only* if a node is already being reprovisioned for another reason.

- **k3s `etcd-snapshot-compress: true`** — ~60–70% smaller snapshots (disk hygiene on CX33). No
  active disk-pressure problem today.
- **k3s `kubelet-arg: serialize-image-pulls=false`** — faster concurrent image pulls on rollout
  bursts; near-zero benefit at 3-node idle.
- **k3s `kube-reserved`/`system-reserved`** — guards kubelet/etcd from pod-memory contention.
  **Do not guess values** — measure system RSS baseline first; eviction thresholds already exist.

---

## REJECTED / already-handled (kept so they're not re-proposed)

- **R0a — cloudflared `--protocol quic`** (was Tier A #1) — **DROPPED: the flag does not exist** in
  current cloudflared (verified absent from `tunnel run --help` on 2026.5.2/2026.6.0; removed years
  ago, transport is now selected server-side). Adding it crash-loops *both* replicas → total ingress
  outage. There is no client-side protocol pin anymore.
- **R0b — cloudflared `--edge-ip-version auto`** (was Tier B #9) — **DROPPED: default is already
  `auto`** (and the flag isn't on `tunnel run`). Nothing to change.
- **R1 — traefik PDB** — *already exists* (`maxUnavailable: 1`, ALLOWED DISRUPTIONS 1 = equivalent
  to minAvailable:1). Verified live. No change.
- **R2 — traefik HTTP/3 / QUIC** — all ingress arrives via the cloudflared TCP tunnel; cloudflared
  speaks HTTP/2 to origin. HTTP/3 at traefik = new UDP Service + Hetzner UDP/443 firewall rule for
  **zero** user-visible benefit (user↔CF already uses QUIC). Don't.
- **R3 — any compression knob** (traefik or cloudflared) — settled in prior work: traefik br q6 is
  measured ~0 CPU (q11=443ms trap), CF re-encodes at edge anyway; cloudflared `--compression-quality`
  would double-compress the fast in-cluster hop. Leave.
- **R4 — cloudflared image pin** — *not* an issue: `kustomization.yaml` already pins
  `newTag: 2026.5.2` + digest. The bare `cloudflare/cloudflared` in deployment.yaml is resolved by
  kustomize before apply.
- **R5 — cloudflared ha-connections / keepalive** — default ha-connections=4 (×2 replicas=8) is
  correct for low traffic; keepalive is dashboard-managed (token mode) at sane CF defaults.
- **R6 — most k3s apiserver tuning** (`--max-requests-inflight`, watch-cache sizes, `--event-ttl`,
  etcd `quota-backend-bytes`, scheduled defrag) — all no-ops at 3-node/idle scale. k3s defrags on
  restart; apiserver compacts etcd every 5m. k3s defaults are correct here.
- **R7 — CF RSC (`?_rsc=`) micro-cache** — deliberately NOT done, and correctly so. On non-Enterprise
  CF you can't vary the cache key on `x-deployment-id`; a micro-cache would serve old-build RSC to
  new-build clients post-deploy → `x-nextjs-deployment-id` mismatch → hard-reload loop. The app-side
  prefetch fix is the safe lever instead.
- **R8 — re-litigating the cluster as the cause of arunanshu.dev/grafana slowness** — already
  exonerated (CF-edge/geography + uncached HTML/RSC). The lever is CF/app, not in-cluster CPU.

---

## Honest bottom line

The cluster is **not CPU-constrained** — there is no footprint win this round, full stop. traefik,
cloudflared and k3s are each already well-configured for a 3-node idle cluster; the agents that went
looking for CPU savings correctly found none. What remains is a small, honest set of **latency/
correctness hygiene** changes (Tier A #2–#7), all gitops/tofu-reversible and most worth doing simply
because they're free insurance on the reboot invariant (cloudflared drain race, traefik rollout
drain, faster CP failover). The one in-cluster *latency* lever needing judgment is traefik
`writeTimeout` (Tier B #8). **The real user-facing win is app-side** — killing the Next.js RSC
prefetch storm — and no amount of in-cluster tuning substitutes for it.

## Suggested rollout

**Gate on every change:** run `helm template` (traefik) / `tofu plan` (CF, LB) and eyeball that the
new key actually appears in rendered output before apply. Two of these had silently-ignored key paths
in v1 — "Synced"/"no diff error" does not prove the change took effect.

1. Tier A #2 (cloudflared, standalone now) — one deploy; watch tunnel reconnect + no request-error bump.
2. Tier A #3–#4 (traefik values) — `helm template` first; ArgoCD sync; watch a rollout produce zero 502s + Tempo spans −90%.
3. Tier A #5–#6 (CF cache) — `tofu plan` (confirm `browser_ttl` lands); `tofu apply`; verify `CF-Cache-Status: HIT` on the new paths.
4. Tier A #7 (LB health-check, gentle 10/5/3) — `tofu apply`; confirm in Hetzner console, `kubectl get nodes` still works; watch for no spurious target removals over a few days.
5. Tier B #8 only after verifying the grafana-p99-is-histogram-ceiling premise AND the dataproxy-timeout/long-stream check.
6. Defer all node-reprovision items; flag the app-side prefetch fix to the arunanshu-dev repo.
</content>
</invoke>
