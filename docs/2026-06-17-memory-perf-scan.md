# Cluster Memory/Perf Scan (2026-06-17)

Goal: safe, non-disruptive perf wins, primary lever = **lower memory usage**,
invariant = **must not reduce observability visibility**, must not raise disruption risk
during a system-update reboot (1 node drains, 2 survive). Simplest solutions.

## Method note (why v1 of this doc was wrong)

The first pass anchored on **VPA recommendations + 14d peaks** and concluded "well-tuned,
leave it." That was a mistake: **VPA happily right-sizes a pod that is leaking, misconfigured,
or shouldn't exist at all.** The real scan is at the **workload-internals** level — runtime/GC,
buffers, ballast, feature flags, replica counts, and *whole pods that aren't needed*. A 5-agent
fleet dug into each component family (tempo, argocd, VM stack, cilium/hubble, platform/apps)
against live config + upstream docs. The wins below are mostly things VPA structurally cannot
surface — three idle pods, 128MB of dead Go ballast, an unused alerting subsystem.

Live baseline: 3× CX33 (~7.3Gi alloc/node), nodes at 66–70% memory. Leak check (9d shape):
cilium/vmagent/grafana **stable sawtooth, not leaking**; the elevated baselines are
**config-driven** (tempo ballast+generator) or **cache** (vmsingle), not leaks.

---

## RANKED — by confidence (the honest axis)

Estimates are aggregate cluster-wide RSS unless noted. "Both cilium files" = a change must go
in *both* `base/infra/cilium/values.yaml` and `bootstrap/values/cilium.yaml.gotmpl` to keep
ArgoCD-adoption render parity (per CLAUDE.md).

### Tier A — bulletproof (zero visibility risk, reboot-safe, ~1 line each)

| # | Change | File | Saves | Why safe |
|---|--------|------|------:|----------|
| 1 | **vmsingle `memory.allowedBytes` 768MB→512MB** | vm-k8s-stack values | **150–220Mi** | Caps RAM **cache** only; 169k active series, TSID cache was 2.4× over-provisioned; data on NVMe, queries just miss-to-disk. Query p99 today 46–300ms → headroom. |
| 2 | **ArgoCD `dex.enabled: false`** | argocd values | **~102Mi** | Dex logs `"dex is not configured"` — no SSO/OIDC/connectors. Deletes a whole idle pod. |
| 3 | **ArgoCD `applicationSet.replicas: 0`** | argocd values | **~74Mi** | Zero ApplicationSet CRs exist (`kubectl get applicationsets -A` empty). Reversible. Deletes a whole idle pod. |
| 4 | **ArgoCD `notifications.enabled: false`** | argocd values | **~27Mi** | Unconfigured (placeholder URL, no subscriptions). Cluster alerting is VMRule-based, not ArgoCD. Deletes a whole idle pod. |
| 5 | **Grafana `unified_alerting.enabled: false`** | vm-k8s-stack values (grafana.ini) | **20–60Mi** | Zero alert rules in Grafana (`/api/v1/provisioning/alert-rules` = `[]`); all alerting is vmalert+vmalertmanager. Dashboards unaffected. |
| 6 | **Tempo `memBallastSizeMbs: 0`** | tempo values | **~40Mi** | Obsolete pre-Go-1.19 GC ballast. NB: the 128MB ballast is **virtual** (zero-page, not RSS) — removing it frees the *secondary* GC-headroom garbage (~50% of idle, per Grafana Cloud #6403), **not** 128MB. Flag deleted in Tempo 3.0. **Must set `0` explicitly** — chart default is 1024, so deleting the key makes it worse. |

**#2+#3+#4 ≈ 203Mi of three idle ArgoCD pods — the headline. VPA structurally cannot surface
these: it right-sizes pods that shouldn't run. Tier A total ≈ 410–620Mi, all reboot-safe.**

### Tier B — one check each, then safe

| # | Change | File | Saves | The check |
|---|--------|------|------:|-----------|
| 7 | **Tempo `local_blocks.filter_server_spans: true`** (restore upstream default) | tempo values | **30–100Mi** off peaks | Keeps root/server spans → all TraceQL `\| rate()`, span-metrics, service-graphs intact. **Check**: no dashboard/alert uses client/producer-span TraceQL metrics (`{ span.kind="client" } \| ...`). If none, safe. |
| 8 | **Grafana `GOMEMLIMIT`** (extraEnv) | vm-k8s-stack values | **0–100Mi** | **NEEDS MEASUREMENT — do not apply blind.** Idle slack is ~352→575Mi but the observed *peak* is 887Mi. Confirm whether 887 is collectable garbage or live render heap: if garbage, `GOMEMLIMIT=500MiB` saves 50–100Mi; if live, a 500 cap makes the GC thrash → sluggish dashboards (a soft visibility/UX hit), so it must be set ≥~900Mi and then saves little. Measure `grafana_go_gc_duration_seconds` + heap before committing. |

### Tier C — marginal hygiene (optional)
- Tempo `service_graphs.max_items: 10000→2000` (~5–15Mi) — verify `..._dropped_spans_total`≈0 first.
- Tempo `local_blocks.max_block_duration: 5m→2m` (~10–25Mi off WAL peaks).
- Grafana `analytics.check_for_updates/reporting_enabled: false` (~0Mi, stops outbound calls).

### Deferred — aggressive, touches the datapath (apply only if you specifically want them)
These are the **worst risk/reward against your stated reboot invariant**: Cilium is the
CNI/kube-proxy/WireGuard datapath, on **pre-release v1.20.0-pre.3 that auto-upgrades**, and these
are the *smallest per-node* wins in the whole list. Recommend deferring.
- **Cilium `envoy.enabled: false`** (both files) — ~94Mi aggregate but only **~31Mi/node**. No L7
  CNP/CEC/proxy-visibility today, DNS proxy is in-agent, flows are eBPF — so functionally safe *now*,
  but cilium#40805 (envoy-disabled preflight failure) is a latent snag on a future auto-upgrade, and
  it must be re-added for the planned L7/default-deny NetworkPolicy work. Apply alone + `just verify-mtu`.
- **Cilium `operator.replicas: 2→1`** (both files) — ~45Mi aggregate (~15Mi/node). Trades away the
  operator standby = a reboot-resilience property, for the smallest win here. Defer.

**Grand total — confident core (Tier A + #7): ~440–720Mi reclaimable, zero observability loss.**

---

## REJECTED (kept so they're not re-proposed)

- **VPA `controlledValues: RequestsOnly` to cap limit overcommit** — limits don't reserve memory; the
  160% overcommit is informational. Capping limits on vmsingle/tempo would trade node-OOM for
  **monitoring-pod-OOM** (the 1852Mi/866Mi peaks are real) = visibility loss. The big limits are protective.
- **Grafana datasources/dashboard sidecars (~226Mi)** — chart 12.3.3 has active bugs in that path
  (grafana/helm-charts #4023/#4031) that silently break datasource/dashboard loading = visibility loss.
- **KEDA / cert-manager `replicas: 2→1`** (~70/25Mi) — their PDBs are `minAvailable: 1`; cutting to 1
  replica deadlocks kured's drain → **blocks reboots**. Net-negative on the reboot invariant.
- **cloudflared `replicas: 2→1`** — sole external egress; 1 replica drops all ingress for 30–60s during
  a node drain. `minReplicaCount: 2` exists for exactly this.
- **arunanshu-dev `NODE_OPTIONS=--max-old-space-size`** — 208Mi idle is real Next.js working set, not GC
  slack; a cap gives no idle win and risks OOM under the known viral-render-bound load.
- **hubble-ui disable (~150Mi)** — it's the tool for the planned L7/default-deny policy validation;
  metrics are independent of it. Optional last-resort lever only.
- **Tempo GOMEMLIMIT / ArgoCD GOMEMLIMIT** — no steady-RSS win (caps spikes only); no OOM pressure today.
- **vmagent streamParse (already on), dedup (single replica), KSM allowlist, search concurrency,
  ArgoCD resource.exclusions (already optimal), redis maxmemory, cilium bpf-map ratio (kernel floor),
  hubble eventBufferCapacity (~2MB), monitor-aggregation (0 RSS)** — marginal or risky.
- **cilium-agent itself** — 274–401Mi is stable/not leaking (Hubble + BPF + endpoint state); the only
  agent-level lever (hubble buffers) costs flow visibility. Leave.

---

## Suggested rollout
All Tier-A changes are GitOps-reversible (ArgoCD self-applies on sync). But several bounce
monitoring-stack pods at once — **stagger them and apply during low traffic**: vmsingle (#1) and
grafana (#5, #8) restarting together is a brief Grafana-down + scrape-cold-start window, which is
itself a transient visibility gap. Sequence: ArgoCD pods (#2–#4, no monitoring impact) → vmsingle
(#1) → grafana (#5) separately → tempo (#6). Then #7 after the TraceQL-query audit; #8 only after
measuring grafana heap. Defer the Cilium items unless specifically wanted. After each: watch
`process_resident_memory_bytes` + query p99 + `hubble observe` + `just verify-mtu`.
