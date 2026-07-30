# Traefik Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development or superpowers:executing-plans to
> implement this plan task-by-task.

**Goal:** Deploy Traefik chart 41.1.0 with safe scaling, memory, placement, and
network controls, and alert when an Argo CD Application stays unhealthy.

**Architecture:** Argo CD continues to render the pinned Traefik chart and
manage the Gateway API resources. KEDA owns replicas, VPA owns requests, and
Cilium limits ingress to the Traefik pods. The Argo application controller
exports metrics through a ServiceMonitor, and the existing cluster-alerts
PrometheusRule sends persistent failures to the existing Alertmanager email
receiver.

**Tech Stack:** Helm, Argo CD 10.2.1, Traefik 41.1.0, KEDA 2.20.1, VPA,
CiliumNetworkPolicy, PrometheusRule, VictoriaMetrics, shell tests.

## Global Constraints

- Work in the current checkout.
- Keep `traefik.arunanshu.dev` behind Cloudflare Access.
- Do not add another authentication prompt.
- Keep at least two Traefik replicas during normal operation.
- Keep the Traefik Service as ClusterIP.
- Do not add new runtime components.
- Prefix local shell commands with `rtk`.

---

### Task 1: Add the configuration test

**Files:**
- Create: `tools/traefik/test-config.sh`
- Modify: `tools/tempo/test-recovery-config.sh`

**Interfaces:**
- Consumes: Traefik Application, values, scaling resources, Cilium policy,
  Argo values, and cluster alerts.
- Produces: one shell command that rejects invalid or unsafe rendered state.

- [ ] **Step 1: Write the failing shell test**

The test must:

```text
read chart version 41.1.0 from the Argo Application
render that exact chart with the repository values
require accessLog flags and reject the old logs key
require an omitted Deployment replica field
require GOMEMLIMIT=921MiB
require DoNotSchedule hostname spread
reject the Kubernetes Ingress provider and IngressClass
require KEDA currentReplicasIfHigher fallback
require the Traefik CiliumNetworkPolicy ports and source selectors
require Argo controller metrics and ServiceMonitor in both Argo values copies
require ArgoCDApplicationNotSynced, ArgoCDApplicationDegraded, and
ArgoCDApplicationMetricsAbsent alerts
```

- [ ] **Step 2: Run the test and verify failure**

Run:

```bash
rtk bash tools/traefik/test-config.sh
```

Expected: non-zero exit because the production configuration has not changed.

- [ ] **Step 3: Update the Tempo test to use the Application chart version**

Replace the hard-coded Traefik chart version with:

```bash
traefik_chart_version="$(
  yq -r '.spec.sources[] | select(.chart == "traefik") | .targetRevision' \
    kubernetes/base/platform/traefik/application.yaml
)"
```

- [ ] **Step 4: Run the existing test and verify it still fails on chart 41**

Run:

```bash
rtk bash tools/tempo/test-recovery-config.sh
```

Expected: chart 41 rejects the old `logs` key.

### Task 2: Correct the Traefik chart and autoscaling configuration

**Files:**
- Modify: `kubernetes/base/platform/traefik/values.yaml`
- Modify: `kubernetes/base/platform/traefik/application.yaml`
- Modify: `kubernetes/components/traefik-scaling/resources/scaledobject.yaml`

**Interfaces:**
- Produces: a chart 41 Deployment that KEDA can scale without Argo CD changing
  replicas.

- [ ] **Step 1: Apply the chart 41 log migration**

Use:

```yaml
accessLog:
  enabled: true
  format: json
  bufferingSize: 100
  filters:
    statusCodes: "400-599"
```

- [ ] **Step 2: Correct replica and memory ownership**

Use:

```yaml
deployment:
  replicas: null
  goMemLimitPercentage: 0.9
```

Remove the custom `GOMEMLIMIT` environment entry.

- [ ] **Step 3: Require node separation and disable unused ingress support**

Set `whenUnsatisfiable: DoNotSchedule`. Set
`providers.kubernetesIngress.enabled: false` and
`ingressClass.enabled: false`.

- [ ] **Step 4: Remove the Argo replica ignore rule**

Remove `spec.ignoreDifferences` from the Traefik Application.

- [ ] **Step 5: Preserve replicas during metric failure**

Add:

```yaml
fallback:
  failureThreshold: 3
  replicas: 2
  behavior: currentReplicasIfHigher
```

Remove `cooldownPeriod` because it has no effect when the minimum replica count
is greater than zero.

### Task 3: Add Traefik ingress isolation

**Files:**
- Create: `kubernetes/components/network-policies/resources/traefik-netpol.yaml`
- Modify: `kubernetes/components/network-policies/resources/kustomization.yaml`

**Interfaces:**
- Produces: ingress isolation for Traefik ports 8000, 8080, and 9100.

- [ ] **Step 1: Add the policy**

Select the Traefik pods. Permit:

```text
cloudflared/app=cloudflared -> TCP 8000
arunanshu-dev/app.kubernetes.io/name=k6 -> TCP 8000
host -> TCP 8000
traefik/app.kubernetes.io/name=traefik -> TCP 8080
host -> TCP 8080
monitoring pods -> TCP 9100
```

Do not define an egress section.

- [ ] **Step 2: Add the policy to the Kustomization**

Add `traefik-netpol.yaml` to `resources`.

### Task 4: Add Argo CD application failure alerts

**Files:**
- Modify: `kubernetes/base/infra/argocd/values.yaml`
- Modify: `kubernetes/bootstrap/values/argocd.yaml`
- Modify: `kubernetes/base/monitoring/cluster-alerts/resources/prometheusrule.yaml`

**Interfaces:**
- Produces: `argocd_app_info` samples and persistent application-state alerts.

- [ ] **Step 1: Enable controller metrics and scraping in both values copies**

Use:

```yaml
controller:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      interval: 30s
      namespace: monitoring
```

Keep the bootstrap and Argo-managed values identical.

- [ ] **Step 2: Add three alerts**

Add a `cluster.argocd` group with a one-minute interval:

```yaml
- alert: ArgoCDApplicationNotSynced
  expr: argocd_app_info{sync_status!="Synced"} == 1
  for: 15m
- alert: ArgoCDApplicationDegraded
  expr: argocd_app_info{health_status="Degraded"} == 1
  for: 10m
- alert: ArgoCDApplicationMetricsAbsent
  expr: absent(argocd_app_info) == 1
  for: 15m
```

Use warning severity for `NotSynced` and critical severity for the other two.
Include the Application name, namespace, sync status, and health status in the
annotations when those labels exist.

### Task 5: Verify, commit, deploy, and monitor

**Files:**
- Test all changed files.

**Interfaces:**
- Produces: a stable live rollout and recorded before-and-after evidence.

- [ ] **Step 1: Run focused tests**

Run:

```bash
rtk bash tools/traefik/test-config.sh
rtk bash tools/tempo/test-recovery-config.sh
rtk kustomize build kubernetes/components/network-policies/resources
rtk kustomize build kubernetes/base/monitoring/cluster-alerts/resources
rtk go run ./cmd/opsctl verify-adoption
```

Expected: all commands exit zero.

- [ ] **Step 2: Run repository checks**

Run the relevant YAML formatting, shellcheck, Helm render, Kustomize, and
configuration validation commands from CI. Expected: all exit zero.

- [ ] **Step 3: Commit and push**

Commit the implementation with:

```bash
rtk git commit -m "fix: harden traefik deployment and alert on Argo failures"
rtk git push
```

- [ ] **Step 4: Synchronize the self-managed Argo CD Application**

The Argo CD Application does not use automated synchronization. Start its sync
after the pushed commit reaches the live root Application. Confirm that the
metrics Service and ServiceMonitor exist before the absence alert reaches its
15-minute threshold.

- [ ] **Step 5: Monitor the rollout**

Confirm:

```text
Traefik Application Synced and Healthy
Traefik chart label 41.1.0
two ready Traefik pods on different nodes
Gateway and all HTTPRoutes Accepted and Programmed
dashboard and public origin requests succeed
argocd_app_info exists in VictoriaMetrics
all three Argo alert rules are loaded
no unexpected firing alerts
no Traefik error increase
```

- [ ] **Step 6: Repeat measurements**

Record pod CPU and memory, VPA recommendation, HPA target and replicas,
request rate, 4xx/5xx rate, and pod placement. Change no thresholds unless the
measurements show a clear need.
