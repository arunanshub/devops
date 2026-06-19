# Unused Optimization Levers — docs-driven sweep (2026-06-19)

**What this is:** a forward-looking inventory of performance/efficiency/reliability features that
**exist in the upstream tools we run but that we are NOT using yet** — read out of the official
docs/changelogs for the pinned versions, then judged for fit. This is a "what could we adopt"
catalogue, *not* a bottleneck analysis. (A separate same-day note,
`2026-06-19-cpu-latency-perf-scan.md`, established the live baseline — cluster is CPU-idle, zero
throttling — and covered request-path latency/drain hygiene. This doc is the capability sweep.)

**Method:** 5 Sonnet agents (traefik, cloudflared, k3s, cilium, VictoriaMetrics), each reading
upstream docs via context7 + exa pinned to our running version, cross-checked against live config
and (where it mattered) live cluster state. Conflicts were reconciled against the actual binaries
(`cloudflared --help`) and live objects (`kubectl`).

**Invariants carried over:** reboot-safe (1 node drains, 2 survive), zero observability loss,
simplest solution, no overengineering. **Reversibility classes:** `gitops` (Helm/ArgoCD values —
revert a line), `node-config` (k3s config drop-in + rolling restart, **no** reprovision, ansible-
deliverable), `reprovision` (cloud-init change, replace node — riskiest), `datapath` (Cilium —
touches the live MTU/WireGuard/VXLAN chain on auto-upgrading v1.20.0-pre.3; run `just verify-mtu`
after, schedule in a window).

---

## k3s (v1.35.5+k3s1) — the richest seam; several genuine wins

| Lever | What it does | Benefit here | Reversibility | Verdict |
|---|---|---|---|---|
| **`--embedded-registry` (Spegel P2P mirror)** | Each node hosts a local OCI mirror + serves images to peers over P2P before hitting Docker Hub/ghcr | On a 3-node cluster, a node that has an image serves it to the others — faster DaemonSet/upgrade rollouts, insulates against Docker Hub rate limits | node-config (must match on all servers; needs intra-cluster TCP 5001) | **YES** — real win, GA since 1.31 |
| **`--secrets-encryption` (at-rest)** | Encrypts Secret objects in etcd (AES-CBC). `k3s secrets-encrypt enable` works on a live cluster | **etcd snapshots go to S3** — today they contain plaintext Secrets (SealedSecrets master key, SOPS keys, hcloud token). This closes an offline-read exposure. | node-config + `secrets-encrypt` rotate flow | **YES** — security/DR. First run `k3s secrets-encrypt status` to confirm it's off |
| **`--etcd-expose-metrics: true`** | Exposes embedded-etcd Prometheus metrics (fsync/commit latency, leader changes, compaction) | We run kube-prometheus/VM but are **blind to etcd health** — these are the first signals before control-plane degradation (cf. the late-caught 2026-06-08 MTU regression) | node-config (CP only) + a ServiceMonitor | **YES** — free observability |
| **`kubelet-arg: serialize-image-pulls=false` (+ `max-parallel-image-pulls=3`)** | Allows concurrent image pulls (k3s serializes by default) | Faster node recovery after a Cilium bump / reboot — pods don't queue one-by-one for images | node-config | **YES** — improves the reboot invariant directly |
| **`kubelet-arg: system-reserved` / `kube-reserved`** | Reserves CPU/mem for OS + k8s daemons so the scheduler under-commits | On 8GB CX33, prevents kubelet/etcd OOM under churn; makes allocatable honest. Eviction thresholds exist but don't model node overhead | node-config | **MAYBE** — measure system RSS first, then set conservative values; don't guess |
| **Faster failover: `--kube-controller-manager-arg: node-monitor-grace-period=20s` + apiserver `default-unreachable/not-ready-toleration-seconds=60`** | Cuts time to declare a dead node + evict its pods from ~5m40s toward ~80s | 3-node cluster — losing a node strands 1/3 of workloads for 5min today | node-config (CP) | **MAYBE** — pair the two; set longer per-workload tolerations on stateful pods (Prometheus WAL) |
| **`--protect-kernel-defaults`** | kubelet refuses to start if kernel sysctls drift from expected (CIS hardening) | Catches silent drift after unattended kernel upgrades | node-config | **MAYBE** — audit `sysctl` (esp. Cilium's VXLAN/WG values) first or it blocks restart |
| **`topology.kubernetes.io/zone` node labels** | Enables topology-aware routing (label side is `kubectl label`, zero-cost, no restart) | 3 nodes in different Hetzner locations — same-zone endpoint preference cuts cross-DC intra-cluster latency. *Routing* side needs Cilium config too | gitops/live label | **MAYBE** — label now (free); evaluate Cilium-side hints separately |
| **`--disable metrics-server`** | Drop k3s-bundled metrics-server | — | — | **NO** — verified running and **VPA depends on it**. Keep. |
| **`--disable local-storage`** | Drop local-path provisioner (currently the *default* SC, 0 PVCs on it) | Removes a footgun: a PVC without an explicit SC silently lands node-local | reprovision | **MAYBE/low** — or just change default SC to `hcloud-volumes-encrypted` |
| stargz snapshotter, `--prefer-bundled-bin`, `--enable-pprof`, dual-stack, `--egress-selector-mode`, `--nonroot-devices` | (various) | no eStargz images / Cilium-eBPF / no device workloads / Hetzner private net is IPv4-only | — | **NO** — inapplicable here |

**Already in use:** `--etcd-snapshot-compress` (ansible drop-in), `--tls-san-security` (default on), etcd→S3 snapshots.

---

## Cilium (v1.20.0-pre.3) — one free latency win, the rest are datapath-risky or blocked

| Lever | What it does | Benefit here | Risk | Verdict |
|---|---|---|---|---|
| **BandwidthManager (`bandwidthManager.enabled=true`)** | MQ/FQ qdiscs on host NICs; EDT pacing; prerequisite for BBR; honors egress-bandwidth annotations | FQ reduces **bufferbloat** on all pod egress — directly relevant to the trans-continental India→CF RTT path. Works **with** VXLAN+WireGuard (orthogonal) | `datapath` — DaemonSet rollout, sets host sysctls; no MTU/CT-map change. Verify `cilium status \| grep BandwidthManager` | **YES (gated)** — lowest-risk real datapath win; do in a window + `just verify-mtu` |
| **BBR (`bandwidthManager.bbr=true`)** | BBR congestion control for pod TCP (vs CUBIC) | Strong fit: cloudflared (internet-facing tunnel) + Next.js serving India/SIN over high-RTT links | `datapath` — needs BandwidthManager first; pod restart to take effect; watch retransmits. Kernel 6.8 ≥ req 5.18 ✓ | **YES (gated)** — enable with BandwidthManager |
| **`bpfClockProbe=true`** | Cheaper jiffies CT-map clock | Small per-packet CT CPU saving | `datapath` — can't hot-enable; existing CT entries misread until they expire (~2h). Per-node at maintenance | **MAYBE** — fold into next node replacement |
| **`bpf.distributedLRU.enabled=true` + `bpf.mapDynamicSizeRatio=0.08`** | Per-CPU CT/NAT LRU (kills spinlock contention) + larger maps (default ratio 0.0025 is very conservative) | Helps cloudflared's many short-lived tunnel conns + vmagent scrape conns under burst | `datapath` — BPF maps recreated → in-flight conns disrupted; per-node at maintenance | **MAYBE** — value real, urgency low at 3-node scale |
| **netkit device mode** | Kernel driver replacing veth; lower ns-switch overhead; unlocks BIG TCP | Modest CPU saving | `datapath` — beta, full pod restart; **netkit's main prize (BIG TCP) is blocked here anyway** | **DEFER** — until BIG TCP viable or veth deprecated |
| **BIG TCP (v4/v6)** | 64KB→192KB GSO/GRO; CPU/byte at high throughput | — | **HARD BLOCKER**: requires tunneling **and** encryption *disabled*. We run VXLAN + WireGuard | **NO** — architecturally incompatible |
| **XDP accel (`bpf.lbAcceleration=native`)** | NodePort/LB forwarding at the NIC driver | — | Hetzner `virtio_net` likely lacks native XDP → silent fallback to (slower) generic XDP. Check `ethtool -i eth0` | **NO/verify** — likely unsupported on virtual NICs |
| Geneve vs VXLAN, Maglev LB, Hubble rate-limiting/queue tuning | (various) | no perf gain over VXLAN / no stateful backends needing affinity / observability loss | — | **NO** unless a specific need appears |

**Note:** eBPF host-routing is **already on** (confirmed via `cilium-dbg status`); `monitorAggregation=medium` is the right default.

---

## VictoriaMetrics (vmsingle/vmagent v1.145.0) — cheap gitops guard-rails & observability

| Lever (extraArgs) | What it does | Benefit | Verdict |
|---|---|---|---|
| **`-search.maxMemoryPerQuery=256MB`** | Per-query RAM cap | Guards the vmsingle pod memory limit (verified 2026-06-19: **~5.18 GiB** limit / ~1.29 GiB request — NOT 2Gi) against a runaway Grafana MetricsQL over ~170k series | **YES** — gitops, 1 line |
| **`-search.logSlowQueryDuration=2s`** | Logs slow queries (+`vm_slow_queries_total`) | Zero-cost early warning on expensive dashboards | **YES** |
| **`-search.logQueryMemoryUsage=64MB`** | Logs memory-heavy queries | Same, for memory | **YES** |
| ~~`-search.cacheTimestampOffset=60s`~~ | **TRIED & REVERTED (b749fb4)** | vmalert writes recording-rule (`:increase30d`) + ALERTS series back with timestamps lagging ~90-113s; a 60s offset makes them "too old" → vmsingle resets the rollup cache every ~10-30s (TooManyLogs + worse hit rate). 5m default tolerates it. **Do not lower.** | **NO** |
| **vmagent `-remoteWrite.maxDiskUsagePerURL=1GB`** | Caps the on-disk WAL queue | vmagent WAL is on ephemeral disk; if vmsingle blips, unbounded WAL can fill the node disk | **YES** — pure safety |
| `-dedup.minScrapeInterval`, `-cacheDataPath`, `-maxIngestionRate`, IndexDB cache % overrides, `noStaleMarkers` | dedup (HA only) / cache-survives-restart / ingestion ceiling / cache tuning | situational | **MAYBE** — only on observed need; check cache miss rates first |
| Downsampling | reduce old-data resolution | — | **NO** — Enterprise-only, and 14d retention = all data is "recent" |

*(Prior scan already set `memory.allowedBytes=512MB` and confirmed `streamParse` on — not re-listed.)*

---

## Traefik (chart 40.3.0 / v3) — mostly observability & drain correctness

| Lever | What it does | Benefit | Verdict |
|---|---|---|---|
| **VPA-aware GOMEMLIMIT** (`deployment.goMemLimitPercentage: 0` + `GOMEMLIMIT` via `resourceFieldRef: limits.memory`) | Chart bakes GOMEMLIMIT at deploy time (256Mi×0.9); VPA then raises the live limit but the soft cap stays frozen → over-GC after each resize. Chart PR #1796 added the `0` opt-out for VPA users | Stops GC thrash after every VPA memory resize. **Verified**: a live VPA *does* manage traefik (`InPlaceOrRecreate`, providing ~203Mi) → finding is real. (Aside: VPA-memory-in-place + KEDA-replicas-on-rps control different axes, so they coexist fine — not the VPA+HPA-same-metric anti-pattern.) | **YES** — gitops, 5 lines |
| **`transport.lifeCycle.requestAcceptGraceTimeout: 5s`** | Keep accepting for 5s after SIGTERM | Closes the rolling-restart 502 gap (KEDA min2/max5 → restarts happen); pairs with cloudflared drain | **YES** |
| **Error-only buffered access logs** (`logs.access` + `bufferingSize:100` + `filters.statusCodes:["400-599"]`) | Logs only 4xx/5xx, buffered | We have **zero** access logs today — 4xx/5xx are invisible beyond a counter. Near-zero cost | **YES** — closes a visibility blind spot |
| **Prometheus histogram buckets** (`[0.005…1.0]`) | Default buckets start at 0.1s | Our p99 is ~ms — current buckets can't see sub-100ms; latency SLO dashboards are blind below 100ms | **YES** — gitops |
| **`serversTransport.forwardingTimeouts.readIdleTimeout: 60s`** | Reaps dead idle HTTP/2 backend conns | Prevents silent dead h2 conns (Tempo OTLP) hanging | **MAYBE** |
| `maxIdleConnsPerHost: 10` (from 200), `GOGC=200`, p2c/leasttime LB strategy, circuit-breaker/retry/inflight/ratelimit middlewares, active health checks | connection-pool right-sizing / GC / per-service resilience | latent — matter mostly when a service runs multi-replica (webapp under KEDA) | **MAYBE** — adopt per-service as KEDA scale-out makes them relevant |
| **`experimental.fastProxy`** (Rust fast path) | Faster proxying | — | **NO (for now)** — silently disables OTLP tracing + OTEL metrics we actively use; revisit when it supports observability |
| HTTP/3, OCSP stapling, TLS session tickets, h2c, sticky sessions, buffering, Hub | — | TLS terminates at CF edge; ingress is behind a TCP tunnel; backends are HTTP/1.1 stateless | **NO** — not applicable behind cloudflared |
| `checkNewVersion: false` / `sendAnonymousUsage: false` | stop outbound calls | hygiene | **YES (trivial)** |

---

## cloudflared (2026.5.2) — thin; transport is server-managed

| Lever | Exists? (verified) | Set via | Verdict |
|---|---|---|---|
| **`--post-quantum`** | YES — in `tunnel --help`, `[$TUNNEL_POST_QUANTUM]` | arg/env | **MAYBE** — enforces hybrid PQ key agreement (removes classical fallback). Zero latency cost; if PQ negotiation fails the replica goes unready and KEDA routes around it. Low-value-but-free hardening |
| **`--output json` logs** (`TUNNEL_LOG_OUTPUT`) | YES | arg/env | **YES** — structured logs make connection-churn/retry-storm/edge-change queryable (metrics already scraped) |
| **CF dashboard tunnel-health alert** + a `cloudflared_tunnel_ha_connections < 4` PrometheusRule | metric already scraped (healthy = 8 = 2×4) | dashboard + gitops VMRule | **YES** — out-of-band + in-cluster alerting on tunnel degradation |
| `--protocol` | historically a real flag (`auto`/`quic`/`http2`); cloudflared selects the best transport itself | arg/env | **NO benefit to pinning** — `auto` is the correct setting; leave it. (We do not rely on a non-existence claim here — just: no reason to override the default.) |
| `--edge-ip-version` | YES but **default already `auto`** | arg/env | **NO** — nothing to change |
| ha-connections (4), origin keepalive/connectTimeout/http2Origin/noHappyEyeballs | dashboard/TF `originRequest` (token mode) | dashboard | **NO/low** — defaults sane; `noHappyEyeballs=true` is the only micro-note (skips IPv6 probe to IPv4-only origin) |

---

## Top picks — what to actually adopt, tiered by effort/risk

**Tier 1 — gitops-only ✅ DONE + pushed (2026-06-19):**
1. ✅ VictoriaMetrics guard-rails: `maxMemoryPerQuery`, `logSlowQueryDuration`, `logQueryMemoryUsage`, vmagent `maxDiskUsagePerURL` (`3561d7e`). NOTE: `cacheTimestampOffset=60s` was tried and **reverted** (`b749fb4`) — it reset the rollup cache every ~10–30s against vmalert's ~90–113s recording-rule/ALERTS lag → TooManyLogs. Keep the 5m default; do not lower.
2. ✅ Traefik: VPA-aware GOMEMLIMIT fix, `requestAcceptGraceTimeout: 5s`, error-only buffered access logs, fine histogram buckets (`7c1317e`). Follow-up: pinned the GOMEMLIMIT `resourceFieldRef` divisor to `"1"` to stop permanent ArgoCD OutOfSync drift (`bf205fb`).
3. ✅ cloudflared: `--output json` logs + `CloudflaredTunnelRedundancyLost` VMRule alert (`sum(cloudflared_tunnel_ha_connections) < 4`; healthy = 8) (`c537fa1`).

**Tier 2 — node-config via ansible (`ansible/playbooks/`, drop-in + `serial:1` rolling restart, NO reprovision).**
Revised phasing agreed 2026-06-19 — batch the cheap additive flags into ONE rolling pass; isolate the two that earn their own pass; park what needs measurement. All 3 nodes are control-plane w/ embedded-etcd HA (`cp-1/2/3` = `10.0.0.2/3/4`, k3s v1.35.5+k3s1), so every server flag lands on all 3.

- **Phase 2 — etcd metrics.** ✅ **2a APPLIED + verified 2026-06-19** (image-pull parallelism was DROPPED — see below).
  - `etcd-expose-metrics: true` (server) → flips etcd `--listen-metrics-urls` from `127.0.0.1:2381` to `0.0.0.0:2381` (plain HTTP `/metrics`). Currently we are BLIND to etcd: `kubeEtcd.enabled=false`, `defaultRules.groups.etcd.enabled=false`, and the kubelet/embedded-binary job drops `(apiserver|etcd)_.*`. Pairs with gitops: enable `kubeEtcd` (static endpoints `10.0.0.2/3/4:2381`, scheme http) + re-enable etcd default rules; KEEP the kubelet-job drop (it now dedups the embedded-binary leak vs the canonical `job=kubeEtcd`). ORDER: ansible flag must land + be verified listening on :2381 BEFORE the gitops scrape ships, else a down-target alert. Firewall: :2381 binds 0.0.0.0, but Hetzner Cloud FW filters only public NICs and node↔node scrape is intra-cluster — confirm 2381 not publicly reachable + scrape works.
  - ~~`serialize-image-pulls=false` + `max-parallel-image-pulls=3` via `kubelet-arg+`~~ **DROPPED 2026-06-19.** k3s v1.35's embedded kubelet rejects `--max-parallel-image-pulls` as an **unknown CLI flag** (it is a KubeletConfiguration *file* field only; `--serialize-image-pulls` IS a real CLI flag) → k3s crash-looped on cp-1 (26 restarts) during the first converge. Clean-reverted (cluster back green in <2min, quorum never lost — `serial:1`+`max_fail_percentage:0` halted before cp-2/cp-3). NOT re-added: keeping `serialize=false` alone would mean *unbounded* parallel pulls (Docker-Hub/disk thundering herd) — worse than the default. Revisit only via a kubelet config file as its own tested change if ever wanted.
  - **Status (2026-06-19): 2a DONE.** Applied via `ansible/playbooks/k3s-etcd-metrics.yml` (etcd-only; handler-based notify `Restart k3s` + `flush_handlers`, `serial:1`/`max_fail_percentage:0`, `ss` non-loopback :2381 verify). Rolling converge succeeded on all 3 CPs (`ok=7 changed=2 failed=0` each). **Verified:** all nodes Ready, `readyz` etcd ok, no firing alerts, `just verify-mtu` clean; and a throwaway pod scraped `http://10.0.0.{2,3,4}:2381/metrics` returning **636/611/609 `etcd_*` series** — proving both the flag took effect and the pod→node:2381 path (which 2b's vmagent will use) works. The `until` readiness wait was hardened with `default([])` (cp-1 is the kubeconfig endpoint and restarts first, so the API is briefly unreachable mid-restart). **2b (etcd scrape + rules) — ✅ DONE 2026-06-19 (commits cfe02db→adb21db).** Gotcha: ArgoCD's `resource.exclusions` drops `Endpoints`/`EndpointSlice`, so the chart's `kubeEtcd` Service-scrape (which needs a manually-populated Endpoints) was applied as Service+VMServiceScrape but the Endpoints was silently NOT applied → **0 targets**. Pivoted to a **`VMStaticScrape`** in `extraObjects` hitting `10.0.0.{2,3,4}:2381` over http (static targets need no Endpoints). Kept `kubeEtcd.enabled=true` ONLY for the etcd rule group (chart gates it on `kubeEtcd.enabled`) with its scrape objects suppressed (`endpoints:[]`, `service.enabled:false`, `vmScrape.enabled:false`) → no cruft. **Verified live:** `up{job=kube-etcd}` 3/3, `etcd_server_has_leader=1` ×3, etcd VMRule (15 alerts) loaded, no false alerts. **No duplicates:** the apiserver job carries etcd-CLIENT metrics (`etcd_request_*` — disjoint names); `:2381` carries the 127 etcd-SERVER names (`etcd_server_*`, `etcd_disk_*`, …). Lesson recorded in memory `argocd-excludes-endpoints-use-vmstaticscrape`.
- **Phase 3 — k3s `embedded-registry: true` (Spegel P2P image mirror).** ✅ **DONE 2026-06-19 (commit 700e754)** via `ansible/playbooks/k3s-embedded-registry.yml` (rolling, serial:1, :5001 listener gate). Two drop-ins in one restart: `embedded-registry: true` + `registries.yaml` with the **`"*"` wildcard** (chosen over explicit: zero-maintenance, covers all 5 in-use registries incl `ecr-public.aws.com` that a 4-entry list missed; safe because NO private/authenticated pulls exist → cred-sharing moot, and v1.35.5 is past the v1.35.1 wildcard-mirror fix #13539). **No firewall change** (5001/6443 ride the Hetzner private net, unfiltered; same as :2381). Default-endpoint fallback ON → worst case = slower pull, never failed. **Verified live:** all 3 CPs enabled + P2P bootstrap-connectivity reached, cp-1/cp-3 advertising (61/66 digests, all 5 registries), and a **proven peer cache-hit** — cp-3 pulled `busybox:1.35.0` from a peer (`spegel_mirror_requests_total{cache="hit"}=5`). **Caveat (RESOLVED — was transient):** cp-2's spegel metrics initially didn't surface via the kubelet-proxy `/metrics` scrape, but this self-resolved — it was a metric-registration lag at startup (matches the `will retry in the background` warning). Re-checked: all 3 nodes now expose an identical 31-line spegel metric set. No action taken; no fix needed. Doc src https://docs.k3s.io/installation/registry-mirror.
- **Phase 4 — k3s `secrets-encryption: true` (highest-value security item; highest care).** VERIFIED: NOT a simple flag on HA — ordered stateful sequence: `k3s secrets-encrypt enable` on one server → restart ALL servers with `secrets-encryption: true` → `k3s secrets-encrypt rotate-keys` → restart all again → verify `Enabled`. Only protects FUTURE etcd writes + FUTURE S3 snapshots (already-taken snapshots stay plaintext). Operator-in-the-loop with playbook assist, not fully autonomous.

**Parked (do NOT do without the stated prerequisite):**
- `kube/system-reserved` / `kube-reserved` — measure live node headroom on the 8GB CX33s first; mis-sizing on small nodes causes evictions.

**Dropped (agreed 2026-06-19):**
- faster-failover (`node-monitor-grace-period`, `*-toleration-seconds`) — on a 3-node cluster with known MTU/WireGuard datapath sensitivity, shrinking the NotReady grace period risks evicting pods on transient blips; with no autoscaler + fixed pool it adds no capacity. Real downside, marginal upside.

**Tier 3 — datapath, schedule in a maintenance window + `just verify-mtu`:**
9. Cilium **BandwidthManager + BBR** — the one genuine *latency* win for the India→CF→cluster path; works with our VXLAN+WireGuard. Everything else Cilium (netkit, distributedLRU, bpfClockProbe) is lower-value and folds into a future node replacement.

**Explicitly blocked / rejected (so they're not re-proposed):** Cilium BIG TCP & XDP (incompatible with our tunnel+encryption / virtual NICs); Traefik HTTP/3, fastProxy, TLS-edge features (behind cloudflared); k3s disable-metrics-server (VPA needs it); cloudflared `--protocol` pin (not a real flag); downsampling (Enterprise + 14d retention).

## Suggested sequencing (agreed 2026-06-19)
- **Tier 1 — ✅ DONE + pushed** (free, reversible, observability-first — the prerequisite for judging everything else).
- **Phase 2 — etcd metrics** ✅ **DONE.** 2a (ansible `k3s-etcd-metrics.yml`) exposes :2381; 2b (gitops) scrapes it via a `VMStaticScrape` + ships etcd rules via `kubeEtcd.enabled`. Image-pull parallelism dropped (k3s kubelet rejects `--max-parallel-image-pulls`).
- **Phase 3 — Spegel embedded registry** ✅ **DONE** (ansible `k3s-embedded-registry.yml`, wildcard mirror, peer cache-hit proven). **Phase 4 (secrets-encryption) ← NEXT.**
- **Phase 3 — Spegel** (`embedded-registry` + `registries.yaml` + firewall verify).
- **Phase 4 — secrets-encryption** (stateful sequence, operator-in-the-loop).
- **Phase 5 (Tier 3) — Cilium BandwidthManager + BBR** last, alone, in a maintenance window, with `just verify-mtu` + Hubble before/after.

Safety over speed: one rolling pass at a time, verify Ready + etcd quorum (2/3) between nodes, ship the gitops scrape only after the flag is confirmed live. The k3s items move the reboot invariant (parallel pulls) and security posture (at-rest encryption) — the most valuable findings, entirely missed by a CPU-usage lens.
