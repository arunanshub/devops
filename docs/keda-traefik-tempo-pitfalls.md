# KEDA, Traefik Tracing, and Grafana Tempo Pitfalls

Lessons from adding KEDA, wiring Traefik OpenTelemetry, and deploying Grafana Tempo single binary.

---

## KEDA: chart name is `keda`, not `kedacore`

**Symptom.** ArgoCD fails to resolve the chart; "chart not found" error.

**Cause.** The Helm repo is named `kedacore` but the chart inside it is named `keda`.

**Fix.**
```yaml
sources:
  - repoURL: https://kedacore.github.io/charts
    chart: keda          # not kedacore
```

**Checklist when adding any new ArgoCD Application.** Four places that must all agree — missing any one causes a silent reject or sync failure:
1. `base/infra/kustomization.yaml` — add `<app>/application.yaml`
2. `appproject.yaml` `sourceRepos` — add the chart's `repoURL`
3. `appproject.yaml` `destinations` — add the target namespace
4. `syncOptions: [CreateNamespace=true]` — if the namespace doesn't already exist

---

## KEDA + Traefik HPA conflict

**Symptom.** Two HPAs exist for the Traefik Deployment; scaling fights itself.

**Cause.** KEDA creates its own HPA internally when a `ScaledObject` targets a Deployment. If `autoscaling.enabled: true` is also set in the Traefik Helm values, two HPAs are created for the same target.

**Fix.** Remove `autoscaling` from Traefik values entirely when using a `ScaledObject`.

---

## Traefik OTLP: two `enabled` flags are required

**Symptom.** Traefik has `--tracing.otlp=true` in its args but sends no traces. Tempo receives nothing. No errors logged anywhere.

**Cause.** `tracing.otlp.enabled: true` activates the OTLP backend but defaults to **gRPC on `localhost:4317`**. The HTTP transport is a separate sub-flag. Without `tracing.otlp.http.enabled: true`, the endpoint value is ignored.

**Fix.**
```yaml
tracing:
  otlp:
    enabled: true
    http:
      enabled: true      # required — without this, gRPC localhost:4317 is used
      endpoint: http://tempo.monitoring.svc.cluster.local:4318/v1/traces
```

Verify via `kubectl get deployment -n traefik traefik -o jsonpath='{...args}'` — all three flags must be present:
```
--tracing.otlp=true
--tracing.otlp.http=true
--tracing.otlp.http.endpoint=http://tempo...
```

---

## No traces despite healthy pipeline

**Symptom.** Tempo is running, Traefik has correct args, Grafana datasource works, but Explore shows zero traces.

**Cause.** Traefik only generates spans for actual HTTP requests it proxies. A freshly deployed cluster with no inbound traffic and only the dashboard IngressRoute produces no spans.

**Fix.** Generate a real request through a Traefik entrypoint. Verify Tempo received it:
```bash
kubectl exec -n monitoring tempo-0 -- wget -qO- "http://localhost:3200/api/search?limit=5"
```
`inspectedTraces > 0` confirms the pipeline is working.

---

## Tempo: `memBallastSizeMbs` default is 1 GiB

**Symptom.** Tempo pod consumes ~1.1 GiB of memory at idle on a small cluster.

**Cause.** The chart default is `memBallastSizeMbs: 1024` — a Go GC tuning knob that pre-allocates a 1 GiB inert byte slice. This is sized for large deployments.

**Fix.** Set `memBallastSizeMbs: 64` for a small single-binary deployment.

---

## Tempo: metricsGenerator storage paths default to `/tmp`

**Symptom.** Metrics generator data is lost on pod restart. Service graph never builds.

**Cause.** The chart defaults `metricsGenerator.storage.path` to `/tmp/tempo` and `traces_storage.path` to `/tmp/traces` — both ephemeral. The main trace storage (`/var/tempo/traces`, `/var/tempo/wal`) correctly lands on the PVC by default, but the metrics generator paths do not.

**Fix.** Explicitly override all four to the PVC mount:
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
    traces_storage:
      path: /var/tempo/metrics-wal
```

---

## Tempo: `local_blocks` processor required for Traces Drilldown

**Symptom.** Grafana Traces Drilldown shows: *"localblocks processor not found"*. TraceQL metrics queries fail.

**Cause.** The `local_blocks` processor maintains a live in-memory+WAL window of recent spans queryable via TraceQL in real time. It is separate from `service_graphs` and is not enabled by default. The error means the processor component exists but was not activated.

**Fix.** Two places must both be set — processor config AND the overrides list:
```yaml
tempo:
  metricsGenerator:
    processor:
      local_blocks:
        flush_to_storage: true
        filter_server_spans: false
        max_block_duration: 5m
  overrides:
    defaults:
      metrics_generator:
        processors:
          - service-graphs   # service map in Grafana
          - local-blocks     # TraceQL metrics + Drilldown
```

`metricsGenerator.enabled: true` activates the component; the `overrides.defaults` list is what tells Tempo which processors to actually run for incoming spans. Both are required.

---

## ServiceMonitor `additionalLabels` not needed in this cluster

`kube-prometheus-stack` is configured with `serviceMonitorSelectorNilUsesHelmValues: false`, which means Prometheus selects **all** ServiceMonitors and PodMonitors cluster-wide regardless of labels. Do not add `additionalLabels: release: kube-prometheus-stack` to any ServiceMonitor — it implies a label requirement that does not exist here.
