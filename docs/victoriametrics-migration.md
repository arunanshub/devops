# VictoriaMetrics migration (Prometheus → VM)

Record of replacing the kube-prometheus-stack **Prometheus server** with
**VictoriaMetrics** (`victoria-metrics-k8s-stack` chart) to cut the monitoring
memory tax. vmsingle + vmagent + vmalert + vmalertmanager replace the Prometheus
StatefulSet; Grafana, kube-state-metrics, node-exporter and Alertmanager are the
same upstream components, just re-bundled by the VM chart.

## Why

Prometheus sat at ~1.6 GiB RSS (VPA floor 512Mi, ceiling 4Gi) — disproportionate for
a single-node homelab with 14d retention. During the parallel run the VM pipeline
(vmsingle 605Mi + vmagent 180Mi + vmalert 97Mi + vmalertmanager 49Mi ≈ 930Mi) already
came in ~40% lower, and vmsingle drops further post-cutover (single scrape, not double).

## Rollout (phased, side-by-side, GitOps via ArgoCD)

1. **Phase 1** — VM stack deployed *alongside* Prometheus; Grafana/KSM/node-exporter
   disabled. vm-operator auto-converts existing ServiceMonitor/PodMonitor/PrometheusRule
   → VM CRDs, so cilium/traefik/cloudflared/keda/tempo/hcloud-ccm definitions stay
   untouched. (PR #30; vmsingle OOM fix #31.)
2. **Phase 2** — Tempo `remoteWriteUrl` + both KEDA `serverAddress` repointed to vmsingle
   `:8428`. (PR #32.)
3. **Phase 3** — VM-managed Grafana enabled + `grafana`/`prometheus` routes cut to VM,
   while kube-prom stays as fallback. (PR #33.)
4. **Phase 4 (cutover)** — neuter kube-prometheus-stack to a CRD-only holder, enable
   VM-managed KSM/node-exporter (ported customizations), port the Alertmanager config
   into vmalertmanager. Clean up orphaned PVCs.

## Lessons / gotchas (the non-obvious bits)

### Do NOT delete the kube-prometheus-stack Application — neuter it instead

The prometheus-operator **CRD *definitions*** (`servicemonitors`/`podmonitors`/
`prometheusrules.monitoring.coreos.com`) are **not in this git repo** — they ship inside
the kube-prometheus-stack chart and are owned by that ArgoCD app (all 10 appear in its
`status.resources`). What *is* in git are CR *instances* (cloudflared ServiceMonitor, the
alert PrometheusRules); many more instances are created at runtime by other charts.

Deleting the app (with `prune: true`) would prune those CRD definitions, and **Kubernetes
garbage-collects every instance of a CRD kind when the CRD is deleted** — cluster-wide,
not via ArgoCD. That would wipe every ServiceMonitor/PodMonitor (cilium, traefik, keda,
tempo, cloudflared, hcloud-ccm) and the VM-converted scrapes → instant monitoring outage.
Also note `Prune=false` on app *deletion* (finalizer cascade) is a different, version-
dependent code path from normal-sync prune — don't rely on it.

**Safe approach:** keep the app in the app-of-apps and edit its `values.yaml`:
- `crds.enabled: true` (keep — CRDs stay explicitly desired, never prune candidates)
- `prometheus.enabled`, `alertmanager.enabled`, `grafana.enabled`,
  `prometheusOperator.enabled`, `kubeStateMetrics.enabled`, `nodeExporter.enabled`: `false`
- `defaultRules.create: false`

Workloads leave desired state → pruned by *normal* sync. No Application deletion → no
finalizer cascade. Fully GitOps, reversible.

`defaultRules.create: false` matters: the VM chart already re-ships the kube-prometheus-mixin
recording/alerting rules (and dashboards). Leaving kube-prom's enabled would duplicate every
rule (the VM operator would convert kube-prom's PrometheusRules into VMRules on top of the VM
chart's own). VM is the single source post-cutover.

### vmsingle memory scales with its limit — cap the cache, don't raise the limit

vmsingle sizes its caches to `-memory.allowedPercent=60%` of the cgroup limit (614MiB at a
1Gi limit), so RSS scales with the limit and a 1Gi limit OOMKilled it. **Raising the limit
makes it use more.** Fix: cap the cache with `-memory.allowedBytes` (set to 350MB here) and
keep the limit as a safety ceiling only. (PR #31.)

### argocdReleaseOverride is mandatory

With `helm.releaseName` set on the Application, the VM chart needs
`argocdReleaseOverride: <ArgoCD app name>` or the generated VMServiceScrapes can't select
the chart's own Services.

### Datasource UID

The VM Grafana datasource is given uid `prometheus` so the bundled kube-prometheus dashboards
(`${DS_PROMETHEUS}`) and Tempo's `serviceMap.datasourceUid: prometheus` resolve with no edits.

### VMAlertmanager secret mount path

The Resend SMTP SealedSecret mounts at `/etc/vm/secrets/alertmanager-smtp/password` under
VMAlertmanager (vs `/etc/alertmanager/secrets/...` under prometheus-operator's Alertmanager).

## Follow-up / TODO (after the migration settles)

- [ ] **Replace the neutered kube-prometheus-stack with the dedicated
  `prometheus-operator-crds` chart** as its own small ArgoCD Application. The neutered chart
  is kept *only* to hold the prometheus-operator CRD definitions (still required because
  third-party charts — cilium, traefik, keda, tempo, cloudflared, hcloud-ccm — emit
  ServiceMonitor/PodMonitor objects that the VM operator converts). A single-purpose
  `prometheus-operator-crds` app provides the same CRDs without the ~200-resource dead chart.
  Do this *after* the migration is stable, and mind the CRD ownership handoff (ServerSideApply
  adoption; ensure the new app owns the CRDs before the neutered chart stops declaring them,
  to avoid the very prune-cascade described above).
- [ ] Reassess vmsingle `-memory.allowedBytes` (350MB) once steady-state, post-cutover
  cardinality is known; raise only if query latency suffers.
