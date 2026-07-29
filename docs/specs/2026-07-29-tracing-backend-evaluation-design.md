# Tracing backend evaluation: Tempo against VictoriaTraces

## Outcome

**Tempo stays.** VictoriaTraces uses less memory, but it generates no span metrics and
no service graph metrics. Two Grafana views in use here depend on those metrics: the
**Service Graph** tab of the Tempo datasource, and the **Traces Drilldown** rate,
error, and duration panels. The features are worth more than the memory.

This document records the comparison, the decision, and a set of Tempo memory levers
that keep both features. The levers are a proposal. This document applies none of them.

## Goal

The task was a documentation-backed study of how Tempo and VictoriaTraces are deployed
and configured through their Helm charts. The primary axis was lower memory use. The
invariant was the same one as `docs/2026-06-17-memory-perf-scan.md`: the change must not
reduce observability.

## Background: why the question came up

`docs/2026-06-17-memory-perf-scan.md` right-sized the monitoring stack. Tempo survived
that pass with a 640Mi memory request and a 1Gi limit, against a measured resident set
of 186Mi. The request is a floor, not a measurement. It exists to escape a 512Mi
out-of-memory loop during write-ahead-log replay. See the comment at
`kubernetes/base/monitoring/tempo/values.yaml:28`.

A 640Mi floor for a 186Mi workload is the largest single piece of over-reservation left
in the `monitoring` namespace. VictoriaTraces claims *"up to 3.7x less RAM and up to
2.6x less CPU than other solutions such as Grafana Tempo"*. So a replacement looked
attractive.

---

## Part 1 — How Tempo is deployed today

| Item | Value | Source |
|---|---|---|
| ArgoCD app | `tempo`, project `monitoring`, sync-wave `2` | `kubernetes/base/monitoring/tempo/application.yaml` |
| Chart | `tempo` **2.2.3**, from `https://grafana-community.github.io/helm-charts` | `application.yaml:14-16` |
| App version | Tempo **2.10.7**, published 2026-06-12 | community `index.yaml`, entry `tempo` |
| Chart currency | 2.2.3 is the newest version in that index. The repo is current. | community `index.yaml` |
| Shape | Single-binary StatefulSet, 1 replica, `fullnameOverride: tempo` | `values.yaml:1` |
| Storage | `backend: local`, PVC 10Gi on `hcloud-volumes-encrypted`, retention `48h` | `values.yaml:10,56-62,94-99` |
| Receivers | OTLP gRPC `:4317`, OTLP HTTP `:4318`. Jaeger and OpenCensus are removed. | `values.yaml:47-54` |
| Query API | `:3200` | chart `values.yaml`, `tempo.server.http_listen_port` |
| Metrics generator | On. Processors `service-graphs` and `local-blocks`. Remote-writes to vmsingle. | `values.yaml:64-85` |
| Memory | Request `640Mi`, limit `1Gi`, `GOMEMLIMIT=800MiB`, `memBallastSizeMbs: 0` | `values.yaml:25-45` |
| Measured resident set | **186Mi** on 2026-06-17. **~227Mi** on 2026-05-30. | `docs/2026-06-17-memory-perf-scan.md:30`, `docs/2026-05-30-sre-reliability-audit.md:360` |
| VPA | `InPlaceOrRecreate`, `RequestsAndLimits`, min `640Mi`, max `1Gi` | `kubernetes/components/monitoring-vpa/resources/vpa-tempo.yaml` |
| Scrape | The chart ServiceMonitor is off. A `VMServiceScrape/tempo-metrics` replaces it. | `victoria-metrics-k8s-stack/values.yaml:431-445` |
| Grafana datasource | `type: tempo`, `uid: tempo`, `:3200`, `nodeGraph` on, `serviceMap` to `prometheus` | `victoria-metrics-k8s-stack/values.yaml:189-199` |
| Producers | Traefik at `sampleRate: 0.05`. `arunanshu-dev` at `parentbased_traceidratio` 0.05. | `base/platform/traefik/values.yaml:97-105`, `base/apps/arunanshu-dev/resources/deployment.yaml:52-65` |

There is no object storage. `docs/specs/2026-05-25-backup-design.md:28` defers the S3
backend until the budget allows it. Trace data has no backup, by decision — see
`docs/backup-restore.md:10`.

---

## Part 2 — How VictoriaTraces would have been deployed

| Item | Value | Source |
|---|---|---|
| Chart | `victoria-traces-single` **0.1.10** | chart `Chart.yaml` |
| App version | **v0.10.0**, published 2026-07-22 | chart `Chart.yaml`, VictoriaTraces changelog |
| Dependency | `victoria-metrics-common` `0.3.*` | chart `Chart.yaml` |
| Chart repo | `https://victoriametrics.github.io/helm-charts/`. It is **already** in the monitoring AppProject `sourceRepos`. An OCI repo also exists at `oci://ghcr.io/victoriametrics/helm-charts`. | `kubernetes/base/monitoring/appproject.yaml`, chart docs |
| Shape | `server.mode: statefulSet`, `server.replicaCount: 1`, headless Service (`clusterIP: None`) | chart `values.yaml:335-368` |
| Ports | HTTP `:10428` only. `server.resources` is `{}` — the chart declares no request and no limit. | chart `values.yaml:100-103,233` |
| OTLP HTTP ingest | `POST /insert/opentelemetry/v1/traces`. It accepts binary protobuf and JSON. | ingestion docs; the blog *Discarding gRPC-Go* |
| OTLP gRPC ingest | **Off by default.** `server.extraArgs.otlpGRPCListenAddr: :4317` turns it on. The chart then adds the container port and a Service port named `otlpgrpc-tcp`. Plain text also needs `otlpGRPC.tls: false`, because that flag defaults to `true`. | chart `templates/server.yaml:98-101` and `templates/service.yaml`; OpenTelemetry setup docs |
| Query APIs | `/select/jaeger` — the stable Jaeger JSON API. `/select/tempo` — **experimental**. `/select/vmui` — its own web UI. | querying docs |
| Retention | `server.retentionPeriod`, default `1`, which means one month. The minimum is 24h. Or `server.retentionDiskSpaceUsage`, which becomes `-retention.maxDiskSpaceUsageBytes`. The chart **fails the render** if both are empty. | chart `templates/_helpers.tpl`, define `vtraces.args` |
| PVC | `server.persistentVolume`, default `10Gi`, `mountPath: /storage`. The chart passes the mount path to `-storageDataPath`. | chart `values.yaml:187-223`, `_helpers.tpl` |
| Memory model | `-memory.allowedPercent` defaults to **60**. It bounds **caches only**. It does not bound the Go heap, memory-mapped files, or goroutine stacks. | VictoriaTraces flag list |
| Hardening | `runAsUser: 1000`, `fsGroup: 2000`, `readOnlyRootFilesystem: true`, and drop `ALL`. All on by default. | chart `values.yaml:267-281` |
| Scrape | `serviceMonitor` and `vmServiceScrape` are both off by default. Metrics are at `/metrics` on `:10428`. | chart `values.yaml:388-435` |
| Dashboard | Grafana.com ID **24136**, *VictoriaTraces - single-node*. The chart ships no dashboard. | Grafana Labs dashboard page |

### Two implementation notes

These cost time to find, so record them.

- Set `server.fullnameOverride: victoria-traces` to fix the object names. Without it the
  chart derives the names from `nameOverride: vt-single` and the release name.
- The PVC name is `<persistentVolume.name or "server-volume">-<statefulset>-<ordinal>`.
  Set `persistentVolume.name: storage` to get `storage-victoria-traces-0`. That is the
  same shape as today's `storage-tempo-0`, which keeps the Ansible playbooks simple.

### The two producers would both work

- **Traefik.** Its `tracing.otlp.http.endpoint` takes a full URL with a path. The
  reference documentation gives the format as `<scheme>://<host>:<port><path>`. So the
  VictoriaTraces path fits directly.
- **`arunanshu-dev`.** The OpenTelemetry specification says an SDK appends `v1/traces`
  to `OTEL_EXPORTER_OTLP_ENDPOINT`, and uses `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`
  as-is. So a base of `http://victoria-traces.monitoring.svc.cluster.local:10428/insert/opentelemetry`
  resolves correctly with no code change.

Neither producer is a blocker. The blocker is in Part 4.

---

## Part 3 — Comparison

| Axis | Tempo 2.10.7 | VictoriaTraces v0.10.0 |
|---|---|---|
| Process count | 1 (single binary) | 1 |
| Storage dependency | None here. `backend: local` on a PVC. | None. Local PVC only. |
| Declared memory | Chart declares nothing. This repo declares 640Mi / 1Gi. | Chart declares nothing. |
| Memory control | `GOMEMLIMIT`, a soft Go target | `-memory.allowedPercent`, caches only |
| Ingest | OTLP gRPC and OTLP HTTP, both on | OTLP HTTP on. OTLP gRPC off by default. |
| Query for Grafana | Native Tempo API | Jaeger API (stable) or Tempo API (experimental) |
| TraceQL filters | Yes | Yes. v0.9.1 added fuzzy match and regular expressions. |
| TraceQL metrics | Yes | **No** |
| Span metrics | Yes | **No** |
| Service graph metrics | Yes | **No** |
| Service dependency graph | Through span metrics | `/select/jaeger/api/dependencies`, which only the Jaeger UI draws |
| Multi-tenancy | Yes | Yes, by `(AccountID, ProjectID)`. It has no built-in authorization. |

The storage axis is often the headline in a Tempo comparison. It is not a
differentiator here, because this Tempo already runs on a local PVC.

---

## Part 4 — The blocker

VictoriaTraces has no metrics generator. So it produces no derived metrics from spans.

### What depends on the Tempo generator today

`kubernetes/base/monitoring/tempo/values.yaml:64-85` runs two processors.

- **`service-graphs`** makes `traces_service_graph_request_*` series. Tempo remote-writes
  them to vmsingle. The Grafana Tempo datasource reads them back through
  `serviceMap.datasourceUid: prometheus`. This draws the **Service Graph** tab.
- **`local-blocks`** keeps recent spans in a live block. This lets Tempo answer TraceQL
  **metrics** queries. Grafana Traces Drilldown needs them for every panel.

### What VictoriaTraces gives instead

The VictoriaTraces changelog is explicit at v0.8.0:

> (experimental) add support for Tempo datasource APIs. This starts with support for the
> basic auto-completion `/tags`, search `/search`, and `/v2/traces/*` APIs. TraceQL
> metrics and pipelines are not yet available in this release.

No release through v0.10.0 adds the metrics endpoint. Later Tempo-API entries are
v0.9.1 (fuzzy match and regular expressions), v0.9.3 (trace by ID, v1 endpoint), and
v0.9.4 (span kinds as strings).

### The effect on each Grafana view

| Grafana view | After a move to VictoriaTraces |
|---|---|
| Explore, Tempo, **Search** tab | Works. Service, span name, duration, and tag filters all map to the search API. |
| Trace waterfall view and node graph | Works. The node graph comes from the spans of one trace, not from metrics. |
| Explore, Tempo, **TraceQL** tab, filter queries | Works. |
| Explore, Tempo, **TraceQL** tab, metrics queries such as `\| rate()` | **Fails.** The endpoint does not exist. |
| Explore, Tempo, **Service Graph** tab | **Fails.** No `traces_service_graph_*` series reach vmsingle. |
| Drilldown, **Traces**, rate, error, and duration panels | **Fails.** Every panel is a TraceQL metrics query. |

Both failures are reachable today, not theoretical:

- The VM stack chart 0.87.0 pins the Grafana subchart at `12.7.*`. Grafana 12 bundles
  all Drilldown applications, so Traces Drilldown needs no installation.
- `docs/keda-traefik-tempo-pitfalls.md:113` records the symptom *"Grafana Traces
  Drilldown shows: localblocks processor not found"*. That error was hit and fixed. So
  Drilldown is in use.
- `docs/2026-06-17-memory-perf-scan.md:30` confirms `traces_service_graph_request_total`
  is live in vmsingle. So the Service Graph tab has data.

Nothing else breaks. No dashboard and no alert rule in this repo queries
`traces_service_graph_*` or `tempo_*`.

### The alternative, and its cost

An OpenTelemetry Collector with the `spanmetrics` and `servicegraph` connectors would
restore both features in front of VictoriaTraces. It adds one pod of roughly 100Mi to
200Mi. That cancels most of the memory win. It also adds a component to the trace
datapath, which is the opposite of the goal.

---

## Part 5 — The honest memory analysis

The marketing ratio is true, but only under its own conditions. State them.

### The upstream benchmark

The VictoriaMetrics developer note gave each component 4 CPUs and 8 GiB. It drove
**10,000 spans per second**. Elasticsearch was excluded, because it began to crash near
5,000 spans per second.

| Component | Memory | CPU | Disk |
|---|---|---|---|
| VictoriaLogs (the VictoriaTraces engine) | 1.15 GiB (14.4%) | 0.50 vCPU | 3.27 GiB |
| ClickHouse | 1.12 GiB (14%) | 0.69 vCPU | 5.86 GiB |
| **Tempo** | **4.26 GiB (53.3%)** | **1.35 vCPU** | ~4.4 GiB |

Tempo also hit an out-of-memory failure in that run. VictoriaLogs and ClickHouse both
held a stable memory profile.

### Why the ratio does not transfer to this cluster

This cluster runs far below 10,000 spans per second. Both producers sample at 5%.
Tempo's measured resident set is **186Mi to 227Mi**, not 4.26 GiB. The 3.7x claim
describes behaviour under load. It does not predict a 3.7x cut at this trace rate.

### What the real prize was

The prize was the **reservation**, not the resident set.

| Quantity | Tempo today | VictoriaTraces, plausible |
|---|---|---|
| Memory request | 640Mi (a floor against a 512Mi replay loop) | ~192Mi |
| Memory limit | 1Gi | ~512Mi |
| Measured resident set | 186-227Mi | Unknown. Only a live deployment can measure it. |

The saving would have been about **450Mi of scheduler reservation** on one CX33 node.
That node has about 7.3Gi allocatable, so the saving is roughly **6% of one node**.
Removal of the generator would also cut vmsingle active series, which is a second and
smaller saving.

Do not promise a number for the VictoriaTraces resident set. This study has no
measurement for this workload, and `-memory.allowedPercent` bounds caches only.

### The trade

450Mi of reservation on one node, against the Service Graph tab and the Drilldown
panels. The features win.

---

## Part 6 — Decision

**Keep Grafana Tempo.** Reason: VictoriaTraces v0.10.0 has no TraceQL metrics endpoint
and no metrics generator, and both Grafana views that depend on them are in use.

Price paid: about 450Mi of memory reservation on one node stays committed.

### Conditions that reopen the question

Each condition is testable. Do not reopen the question without one.

1. VictoriaTraces ships the TraceQL metrics endpoint, **and** its Tempo API leaves
   experimental status.
2. The trace rate rises far enough that Tempo memory becomes the binding constraint on
   a node.
3. The Service Graph tab and the Drilldown panels fall out of use.

---

## Part 7 — Tempo memory levers (proposed, not applied)

Every default below comes from the Tempo **v2.10.7** source, at the tag that chart 2.2.3
pins. The chart exposes `tempo.ingester`, `tempo.querier`, `tempo.queryFrontend`,
`tempo.storage`, `tempo.overrides`, and `tempo.metricsGenerator.processor`. So every
lever is reachable from `kubernetes/base/monitoring/tempo/values.yaml`.

### Three current values deviate from the upstream default

| Key | This repo | Upstream default | Effect |
|---|---|---|---|
| `local_blocks.filter_server_spans` | `false` | `true` | Stores every span kind, not only server and root spans |
| `local_blocks.max_block_duration` | `5m` | `1m` | Five times the default live block |
| `service_graphs.max_items` | `10000` | `10000` | No effect. It restates the default. |

The first two came from the chart's own commented example, which shows exactly
`filter_server_spans: false` and `max_block_duration: 1m`. The copy site is
`docs/keda-traefik-tempo-pitfalls.md:118-128`. Note that the copy kept `false` but
changed `1m` to `5m`. Neither value was measured.

### Tier 1 — restore an upstream default. Lowest risk.

| Lever | Now | Proposed | Estimate | Check |
|---|---|---|---|---|
| `metricsGenerator.processor.local_blocks.max_block_duration` | `5m` | `1m` | 10-25Mi off write-ahead-log peaks | None. It restores the default. |
| `metricsGenerator.processor.service_graphs.max_items` | `10000` | `2000` | 5-15Mi | `..._dropped_spans_total` must stay near zero. |
| `metricsGenerator.processor.local_blocks.complete_block_timeout` | unset, so `1h` | `15m` | Frees generator blocks sooner | Drilldown must still cover the time window you query. |

### Tier 2 — cap an uncapped ceiling. Low risk, and protective.

Tempo 2.10.7 leaves several large ceilings unset on a 1Gi pod.

| Lever | Default | Proposed | Reason |
|---|---|---|---|
| `local_blocks.max_live_traces_bytes` | `250000000` (250MB) | `33554432` (32MiB) | A 250MB live-trace ceiling on a 1Gi pod. Excess traces drop; the pod does not. |
| `ingester.max_block_bytes` | `524288000` (500MiB) | `67108864` (64MiB) | The head block is the largest single buffer. Smaller blocks cut more often, and the compactor merges them. |
| `ingester.max_block_duration` | `30m` | `10m` | Cuts head-block residency. |
| `overrides.defaults.metrics_generator.max_active_series` | unset, so uncapped | `5000` | Bounds registry growth. Purely protective. |
| `storage.trace.pool.max_workers` | `30` | `8` | 30 query workers on a one-user, one-replica install. |
| `querier.max_concurrent_queries` | `20` | `4` | The same reason. It affects query peaks only. |

`query_frontend.search.concurrent_jobs` is a further candidate. The chart comment says
`2000`. The source uses a named constant that this study did not resolve. Resolve the
constant before you propose a number.

### Tier 3 — costs visibility. Needs an explicit decision.

| Lever | Now | Proposed | Estimate |
|---|---|---|---|
| `local_blocks.filter_server_spans` | `false` | `true` | 30-100Mi off peaks |

`docs/2026-06-17-memory-perf-scan.md:63` says this lever keeps all TraceQL `| rate()`
queries intact. That understates the cost. The source is exact. `filterBatches` in
`modules/generator/processor/localblocks/processor.go:967-997` keeps a span only when
its kind is `SPAN_KIND_SERVER`, **or** the span has no parent. So `true` drops client,
internal, producer, and consumer spans from the local-blocks store.

What that means:

- Drilldown rate, error, and duration per service still work. Those are server spans.
- A TraceQL metrics query filtered on a non-server span kind returns nothing. You lose
  the aggregate rate and duration of the outbound client calls of `arunanshu-dev` and
  of Traefik.
- Trace search and the waterfall view are **not** affected. They read the ingester and
  the backend blocks, not local-blocks.
- The `service-graphs` processor is **not** affected. It is a separate processor.

The check is a question, not a command: do you ever drill into client spans?

### Rejected, with the reason

Keep these here so nobody proposes them again.

- **A Tempo `GOMEMLIMIT` change.** `docs/2026-06-17-memory-perf-scan.md` already
  rejected it. It caps spikes and gives no steady-state win.
- **VPA `controlledValues: RequestsOnly` for Tempo.** The comment at
  `kubernetes/base/monitoring/tempo/values.yaml:34-42` explains that this surrenders the
  write-ahead-log replay headroom.
- **A lower memory limit.** `docs/specs/2026-07-12-memory-limit-rightsizing-design.md:55`
  marks Tempo's 1.27x headroom as deliberate, and says it must not shrink.

### If the levers are applied

- Apply Tier 1 as one commit. Watch `process_resident_memory_bytes` for the Tempo pod.
- Apply Tier 2 as a second commit. Watch the same metric, and the dropped-span and
  dropped-trace counters.
- Decide Tier 3 only after you answer the client-span question.
- Every change restarts the Tempo pod. `docs/2026-06-17-memory-perf-scan.md` warns to
  stagger monitoring-pod restarts. Apply one commit at a time.

---

## Sources

Repository files are cited inline above. External sources:

**VictoriaTraces**

- Overview and flag list — <https://docs.victoriametrics.com/victoriatraces/>
- Helm chart — <https://docs.victoriametrics.com/helm/victoria-traces-single/>
- Chart source — <https://github.com/VictoriaMetrics/helm-charts/tree/master/charts/victoria-traces-single>
- Data ingestion — <https://docs.victoriametrics.com/victoriatraces/data-ingestion/>
- OpenTelemetry setup — <https://docs.victoriametrics.com/victoriatraces/data-ingestion/opentelemetry/>
- Querying — <https://docs.victoriametrics.com/victoriatraces/querying/>
- Grafana — <https://docs.victoriametrics.com/victoriatraces/querying/grafana/>
- Changelog — <https://docs.victoriametrics.com/victoriatraces/changelog/>
- Benchmark against Tempo and ClickHouse — <https://victoriametrics.com/blog/dev-note-distributed-tracing-with-victorialogs/>
- OTLP transports — <https://victoriametrics.com/blog/opentelemetry-without-grpc-go/>
- Self-monitoring dashboard — <https://grafana.com/grafana/dashboards/24136-victoriatraces-single-node/>

**Tempo**

- Configuration — <https://grafana.com/docs/tempo/latest/configuration/>
- `local_blocks` defaults — <https://github.com/grafana/tempo/blob/v2.10.7/modules/generator/processor/localblocks/config.go>
- `filterBatches` — <https://github.com/grafana/tempo/blob/v2.10.7/modules/generator/processor/localblocks/processor.go>
- `service_graphs` defaults — <https://github.com/grafana/tempo/blob/v2.10.7/modules/generator/processor/servicegraphs/config.go>
- Ingester defaults — <https://github.com/grafana/tempo/blob/v2.10.7/modules/ingester/config.go>
- Querier defaults — <https://github.com/grafana/tempo/blob/v2.10.7/modules/querier/config.go>
- Query-frontend defaults — <https://github.com/grafana/tempo/blob/v2.10.7/modules/frontend/config.go>
- Storage pool defaults — <https://github.com/grafana/tempo/blob/v2.10.7/tempodb/pool/config.go>
- Chart index — <https://grafana-community.github.io/helm-charts/index.yaml>

**Grafana and OpenTelemetry**

- Traces Drilldown access — <https://grafana.com/docs/grafana/latest/explore/simplified-exploration/traces/access/>
- Traefik tracing reference — <https://doc.traefik.io/traefik/reference/install-configuration/observability/tracing/>
- OTLP exporter environment variables — <https://opentelemetry.io/docs/specs/otel/protocol/exporter/>
