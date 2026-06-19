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
| **`-search.maxMemoryPerQuery=256MB`** | Per-query RAM cap | Guards the 2Gi ceiling against a runaway Grafana MetricsQL over 169k series | **YES** — gitops, 1 line |
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

**Tier 1 — gitops-only, do now (revert = one line):**
1. VictoriaMetrics guard-rails: `maxMemoryPerQuery`, `logSlowQueryDuration`, `logQueryMemoryUsage`, vmagent `maxDiskUsagePerURL`. (`cacheTimestampOffset` was tried and reverted — see table.)
2. Traefik: VPA-aware GOMEMLIMIT fix, `requestAcceptGraceTimeout: 5s`, error-only buffered access logs, histogram buckets, kill version-check/usage calls.
3. cloudflared: `--output json` logs + a tunnel-HA-connections VMRule alert.

**Tier 2 — node-config drop-in + rolling restart (ansible, NO reprovision):**
4. k3s `--secrets-encryption` (encrypts S3 etcd snapshots — highest-value security item).
5. k3s `--embedded-registry` (Spegel — faster rollouts, Docker-Hub-rate-limit insulation).
6. k3s `--etcd-expose-metrics` + ServiceMonitor (etcd health visibility).
7. k3s `serialize-image-pulls=false` + `max-parallel-image-pulls=3` (faster node recovery → helps reboot invariant).
8. (Optional) k3s faster-failover args + `kube/system-reserved` (measure first).

**Tier 3 — datapath, schedule in a maintenance window + `just verify-mtu`:**
9. Cilium **BandwidthManager + BBR** — the one genuine *latency* win for the India→CF→cluster path; works with our VXLAN+WireGuard. Everything else Cilium (netkit, distributedLRU, bpfClockProbe) is lower-value and folds into a future node replacement.

**Explicitly blocked / rejected (so they're not re-proposed):** Cilium BIG TCP & XDP (incompatible with our tunnel+encryption / virtual NICs); Traefik HTTP/3, fastProxy, TLS-edge features (behind cloudflared); k3s disable-metrics-server (VPA needs it); cloudflared `--protocol` pin (not a real flag); downsampling (Enterprise + 14d retention).

## Suggested sequencing
Tier 1 first (free, reversible, mostly observability — and observability is the prerequisite for
judging everything else). Then Tier 2 secrets-encryption + embedded-registry as a single ansible
rolling pass. Tier 3 Cilium BandwidthManager+BBR last, alone, in a window, with `just verify-mtu`
and Hubble before/after. The k3s items genuinely move the reboot invariant (parallel pulls, faster
failover) and the security posture (at-rest encryption) — they're the most valuable findings here
and were entirely missed by a CPU-usage lens.
</content>
