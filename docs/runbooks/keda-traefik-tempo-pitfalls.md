# KEDA, Traefik Tracing, and Grafana Tempo Pitfalls

Failures from KEDA, the Traefik OpenTelemetry wiring, and the Tempo single binary.
Tempo runs chart 3.0.0 (Tempo 3.0.3) since 2026-09-11.

---

## KEDA: the chart name is `keda`, not `kedacore`

**Symptom.** ArgoCD reports "chart not found".

**Cause.** The Helm repo is `kedacore`. The chart inside it is `keda`.

**Fix.**

```yaml
sources:
  - repoURL: https://kedacore.github.io/charts
    chart: keda # not kedacore
```

**4 places must agree for any new Application.** Miss one and the sync fails silently.

1. `base/<group>/kustomization.yaml` — add `<app>/application.yaml`.
2. `appproject.yaml` `sourceRepos` — add the chart `repoURL`.
3. `appproject.yaml` `destinations` — add the namespace.
4. `syncOptions: [CreateNamespace=true]` — only if the namespace is new.

---

## KEDA and Traefik make 2 HPAs

**Symptom.** Two HPAs target the Traefik Deployment. They fight.

**Cause.** KEDA creates its own HPA for a `ScaledObject`. `autoscaling.enabled: true` in
the Traefik values creates a second one.

**Fix.** Remove `autoscaling` from the Traefik values. Keep the `ScaledObject`.

---

## Traefik OTLP needs 2 `enabled` flags

**Symptom.** Traefik runs with `--tracing.otlp=true` and sends no traces. No component
logs an error.

**Cause.** `tracing.otlp.enabled: true` selects the backend, which defaults to gRPC on
`localhost:4317`. Traefik ignores `endpoint` until `tracing.otlp.http.enabled: true` is set.

**Fix.**

```yaml
tracing:
  otlp:
    enabled: true
    http:
      enabled: true # required, or Traefik uses gRPC localhost:4317
      endpoint: http://tempo.monitoring.svc.cluster.local:4318/v1/traces
```

Verify all 3 args are present:

```bash
kubectl get deployment -n traefik traefik -o jsonpath='{..args}'
# --tracing.otlp=true
# --tracing.otlp.http=true
# --tracing.otlp.http.endpoint=http://tempo...
```

---

## No traces, but every component is healthy

**Symptom.** Every component is healthy, but Explore shows 0 traces.

**Cause.** Traefik emits a span only for a request that it proxies. A cluster with no
inbound traffic produces no spans.

**Fix.** Send a real request through a Traefik entrypoint. Then query Tempo.

**The Tempo 3.0.3 image has no `wget` and no `curl`.** `kubectl exec` cannot query the
API. Use a port-forward.

```bash
kubectl port-forward -n monitoring tempo-0 3200:3200 &
curl -s 'localhost:3200/api/search?limit=5'
```

A non-empty `traces` array confirms the pipeline.

---

## Tempo: the metricsGenerator path defaults to `/tmp`

**Symptom.** The metrics-generator loses its data on a pod restart. The service graph
never builds.

**Cause.** The chart defaults `metricsGenerator.storage.path` to the ephemeral
`/tmp/tempo`. The trace paths land on the PVC by default. This one does not.

**Fix.** Point all 3 paths at the PVC mount.

```yaml
tempo:
  storage:
    trace:
      local:
        path: /var/tempo/traces
      wal:
        path: /var/tempo/wal
  metricsGenerator:
    storage:
      path: /var/tempo/metrics
```

Chart 3.0.0 removed a 4th path, `metricsGenerator.traces_storage`. It belonged to the
`local_blocks` processor. Do not set it.

---

## Tempo 3.0 removed 4 values that this repository used to set

**Symptom.** After the chart 2.3.0 to 3.0.0 bump the pod crash-loops:

```
failed parsing config: field local_blocks not found in type generator.ProcessorConfig
```

**Cause.** Chart 3.0.0 runs Tempo 3.0.3, not 2.10.8. Tempo 3.0 rebuilt the write path.
The live-store replaces the ingester. The backend-scheduler replaces the compactor.

**Fix.** Remove all 4 items. Tempo 3.0 refuses to start while either of the first 2
remains.

| Removed | Reason |
|---|---|
| `metricsGenerator.processor.local_blocks` | Tempo 3.0 deleted the processor. |
| `local-blocks` in `overrides.defaults...processors` | The name is no longer valid. |
| `metricsGenerator.traces_storage` | The chart no longer renders it. |
| `memBallastSizeMbs` | Tempo 3.0 dropped the `-mem-ballast-size-mbs` flag. |

**Traces Drilldown keeps working.** The live-store now serves the TraceQL metrics queries
on recent data. This is the direct replacement for `local_blocks`. No values key turns it
on. Prove it with a `{}|rate()` query over the last 5 minutes.

Two renames come with the bump. `tempo.ingester` becomes `tempo.liveStore`.
`tempo.retention` renders into
`backend_scheduler.provider.compaction.compaction.block_retention`.

The live-store `max_block_duration` default is 30s. The old ingester default was 30m, so
Tempo 3.0 writes more and smaller blocks. Watch `tempodb_blocklist_length`. Raise
`tempo.liveStore.max_block_duration` if it climbs.

`backend-worker` logs `level=error ... no jobs found` when no compaction job exists.
Backoff settles the rate near 1.2 lines per minute. This noise is benign.

---

## Tempo: you cannot close the 4 jaeger receivers on chart 3.0.0

**Symptom.** The values file sets only `receivers.otlp`, but the rendered config still
opens 4 jaeger ports.

**Cause.** The chart default adds jaeger. A Helm map merge keeps a default that you only
omit. All 3 workarounds fail:

- `jaeger: null` and `protocols: {}` both break the render. `_ports.tpl` reads
  `receivers.jaeger.protocols.thrift_compact` with no nil guard.
- An empty protocol map renders, but the receiver then uses its own default endpoint. The
  port still listens and the Service hides it. That result is worse.

**Fix.** None exists. The ports stay inside the cluster and the Gateway does not expose
Tempo. Do not claim in a comment that the values file drops them.

---

## Verify a chart major bump before you push it

A `helm template` render is not proof. The config parser stops at the **first** unknown
key, so only a boot test finds every removed value.

1. Read the chart `README.md` "Upgrading" section. Get it with
   `helm pull <chart> --version <v> --untar`.
2. Render the config, then start the real image against it.

```bash
helm template tempo grafana-community/tempo --version 3.0.0 -f values.yaml \
  | yq 'select(.kind=="ConfigMap" and .metadata.name=="tempo") | .data."tempo.yaml"' \
  > /tmp/t/tempo.yaml
# Copy overrides.yaml beside it. The overrides module fails without that file.
docker run --rm -v /tmp/t:/conf grafana/tempo:3.0.3 -config.file=/conf/tempo.yaml
```

Look for `Tempo started`.

3. Read a live default from the binary, never from memory:
   `curl localhost:3200/status/config`.

---

## ServiceMonitor `additionalLabels` is not needed in this cluster

`vmagent` runs with `selectAllByDefault: true`, so it selects every scrape object whatever
the labels. The VictoriaMetrics operator converts each ServiceMonitor and PodMonitor into
a VM-native scrape.

Do not add `additionalLabels: release: kube-prometheus-stack` to a ServiceMonitor. That
label implies a requirement that does not exist. The `kube-prometheus-stack` chart is
neutered here and runs no Prometheus. It supplies only the CRDs.
