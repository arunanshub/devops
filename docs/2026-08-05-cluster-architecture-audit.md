# Cluster architecture audit — 2026-08-05

## Scope and method

This is a read-only review of the repository and its live Kubernetes cluster.
It covers 368 tracked files, including 205 Kubernetes YAML files. Encrypted
SOPS and SealedSecret payloads were not decrypted or exposed; their structure,
target names, and namespaces were reviewed.

The live checks found three Ready control-plane nodes, 47 Argo CD Applications
that were Synced and Healthy, passing etcd snapshot and Velero restore checks,
and no Warning events.

## Executive summary

The cluster architecture is sound for three control-plane nodes. The material
risks are in emergency automation and recovery documentation, rather than the
live data plane:

1. The multi-server etcd restore procedure is incomplete.
2. Prometheus-era PV migration and Talos cutover automation is still runnable,
   but targets workloads that no longer exist.
3. Three Justfile helpers reference obsolete paths or resource names.
4. Backup retention policy and Terraform state ownership need an explicit
   decision.

No repository or cluster change was made by this audit.

## Inventory ledger

| Area | Reviewed content | Status |
|---|---|---|
| Terraform | 18 files under `infra/` | Findings on local state and retention |
| Ansible and nodes | 16 Ansible files and 7 K3s node drop-ins | Legacy migration findings |
| GitOps bootstrap | Root manifests, AppProjects, Helmfile, bootstrap values | Root-project finding |
| Applications | `kubernetes/base/apps/**` | Revision and helper findings |
| Components | `kubernetes/components/**` | Cloudflared egress finding |
| Monitoring | `kubernetes/base/monitoring/**` | CRD-only chart simplification |
| Platform | `kubernetes/base/platform/**` | No concrete runtime defect |
| Go and tools | `cmd/**`, `internal/**`, `tools/**` | No concrete defect; tests pass |
| Documentation | `docs/**` | Restore and PV-operation instructions are stale |

The following controls were reviewed and no concrete problem was identified:

- Cilium API-server egress uses the identity-based `kube-apiserver` rule.
- Cloudflared replica count, PodDisruptionBudget, and topology spreading support HA.
- Cilium VXLAN plus WireGuard is deliberate and has matching MTU controls.
- Helmfile-to-Argo adoption has a repository regression guard and currently matches.
- One-node-at-a-time Ansible convergence, CoreDNS HA, and Terraform
  `prevent_destroy` controls are justified.

## Architecture

```text
Terraform -> Hetzner, Cloudflare, R2, network, load balancer
Ansible -> K3s nodes and rolling control-plane configuration
Helmfile -> Cilium, Hetzner CCM, Argo CD bootstrap
Argo CD -> all steady-state Kubernetes resources
Cloudflare Tunnel -> cloudflared -> Traefik Gateway -> HTTPRoute -> workload
VictoriaMetrics / Tempo / Velero / etcd snapshots -> observability and recovery
```

## Findings

### High — etcd restore procedure cannot safely rejoin all peers

**Evidence.** [Justfile](../Justfile) and
[backup-restore.md](backup-restore.md) stop every node, reset one server, and
then start the remaining servers without removing their previous K3s database
directories. They also use `cp-0`, but the live nodes are `cp-1` through
`cp-3`.

**Failure mode.** An emergency restore can fail to form a clean three-member
etcd cluster or leave peers with stale membership state.

**Recommendation.** After the reset server is healthy, stop each peer, remove
`/var/lib/rancher/k3s/server/db/`, and start peers one at a time. Add an
explicit destructive confirmation and rehearse this procedure on three test
nodes.

**Primary source.** [K3s etcd snapshot and restore](https://docs.k3s.io/cli/etcd-snapshot).

**Confidence:** confirmed.

### High — runnable PV and Talos migration automation targets retired workloads

**Evidence.**

- `ansible/playbooks/ops/recreate-encrypted-pvcs.yml`
- `ansible/playbooks/ops/migrate-prometheus-encrypted.yml`
- `ansible/playbooks/ops/talos-pre-cutover.yml`
- `ansible/playbooks/ops/talos-post-bootstrap.yml`
- [pv-encryption-pitfalls.md](pv-encryption-pitfalls.md)

These files reference kube-prometheus-stack Grafana, Prometheus, Alertmanager,
and the Prometheus Operator. The live monitoring workloads are VictoriaMetrics,
Tempo, and `victoria-metrics-k8s-stack-grafana`. Some recipes stop the Argo CD
application controller before attempting to stop a nonexistent workload.

**Failure mode.** A failed emergency command can leave Argo CD stopped, while
the requested storage operation has not started.

**Recommendation.** Move obsolete recipes out of runnable operations, or
rewrite them for the current PVCs and workloads. Add preflight existence checks
before pausing Argo CD and an `always` recovery path that restarts it.

**Confidence:** confirmed.

### Medium — Justfile helpers use stale names and paths

**Evidence.**

- `launch-grafana` points at `kube-prometheus-stack-grafana`, not the live
  VictoriaMetrics Grafana Service.
- `seal-cloudflared-token` writes below a nonexistent `base/infra/cloudflared`
  path.
- `seal-cf-cache-purge` creates `sealed-cf-cache-purge.yaml`, while Kustomize
  includes `cf-cache-purge.sealedsecret.yaml`.

**Recommendation.** Correct the names and paths, then add tests that assert
the output path exists and is included by the target Kustomization.

**Confidence:** confirmed.

### Medium — cloudflared has wider egress than its selected protocol needs

**Evidence.** [cloudflared deployment](../kubernetes/components/cloudflared/resources/deployment.yaml)
forces HTTP/2, while its [Cilium policy](../kubernetes/components/network-policies/resources/cloudflared-netpol.yaml)
allows both UDP and TCP on 7844 and TCP/443 to `world`.

**Recommendation.** Roll one replica and observe tunnel readiness, connection
count, and Hubble drops. If healthy, retain only TCP/7844 to Cloudflare edge
ranges, DNS, and Traefik. Restore UDP if the connector returns to QUIC.

**Primary sources.** [Cloudflare firewall guidance](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/)
and [connectivity prechecks](https://developers.cloudflare.com/changelog/post/2026-05-27-cloudflared-connectivity-prechecks/).

**Confidence:** configuration confirmed; removal needs live measurement.

### Medium — Terraform state is encrypted but local-only

**Evidence.** `infra/main.tf` defines state encryption but no backend. Local
state is intentionally gitignored.

**Failure mode.** Laptop loss or overlapping applies can lose state recovery
and coordination.

**Recommendation.** Use a remote backend with recovery and locking semantics.
HCP Terraform is the simple option. Use an S3-compatible backend only after
checking its versioning and lock behavior.

**Primary sources.** [Terraform remote state](https://developer.hashicorp.com/terraform/language/state/remote)
and [S3 backend locking](https://developer.hashicorp.com/terraform/language/backend/s3).

**Confidence:** confirmed configuration; operational impact depends on process.

### Medium — etcd and object-storage retention describe different recovery windows

**Evidence.** The K3s node configuration retains 48 remote snapshots at a
six-hour interval, or about 12 days. R2 lifecycle configuration says 45 days.
Velero has a 30-day backup TTL.

**Recommendation.** Choose one intended retention period for each backup type.
Set K3s retention to that period, or document 12 days as authoritative. Test
the oldest retained snapshot and a Velero restore.

**Primary source.** [Cloudflare R2 object lifecycle rules](https://developers.cloudflare.com/r2/buckets/object-lifecycles/).

**Confidence:** confirmed inconsistency.

### Medium — root GitOps application uses Argo CD's unrestricted default project

**Evidence.** `kubernetes/root-application.yaml` sets `project: default`.

**Failure mode.** A repository write compromise can define child Applications
with the default project's broad source, destination, and resource authority.

**Recommendation.** Create a restricted bootstrap AppProject for the root
application. Limit its repository, destination, and allowed resource kinds.
Migrate in stages and test clean bootstrap recovery.

**Primary source.** [Argo CD Projects](https://argo-cd.readthedocs.io/en/stable/user-guide/projects/).

**Confidence:** confirmed.

### Medium — kube-prometheus-stack is only a CRD holder

**Evidence.** `kubernetes/base/monitoring/kube-prometheus-stack/values.yaml`
disables all workloads and retains the chart only for Prometheus Operator CRDs.

**Recommendation.** Move the CRDs to a small dedicated application. Adopt them
with Server-Side Apply before disabling the existing chart CRDs. Never prune
the existing application before ownership transfer is proven.

**Primary source.** [VictoriaMetrics Kubernetes stack](https://docs.victoriametrics.com/helm/victoria-metrics-k8s-stack/).

**Confidence:** confirmed simplification opportunity.

### Low — vmsingle VPA comment contradicts the selected update mode

**Evidence.** `vpa-vmsingle.yaml` says it is `Initial`, but configures
`InPlaceOrRecreate`.

**Recommendation.** Select one policy and make the comment match. For a
single replica on RWO storage, `Initial` is the lower-disruption policy.

**Primary source.** [Kubernetes Vertical Pod Autoscaling](https://kubernetes.io/docs/concepts/workloads/autoscaling/vertical-pod-autoscale/).

**Confidence:** confirmed.

### Low — one Application tracks `HEAD` while the repository convention is `master`

**Evidence.** `kubernetes/base/apps/arunanshu-dev/application.yaml` uses
`targetRevision: HEAD`; the root and other Applications use `master`.

**Recommendation.** Use `master`, unless default-branch tracking is intentional
and documented.

**Confidence:** confirmed.

## Simplification plan

1. Correct and rehearse etcd recovery before the next control-plane change.
2. Archive or rewrite obsolete Prometheus/Talos migration commands.
3. Repair and test the three Justfile helpers.
4. Decide backup retention and remote Terraform-state policy.
5. Transfer Prometheus Operator CRD ownership to a dedicated application.
6. Measure cloudflared egress before reducing it.
7. Retain HA controls, Cilium policy, bootstrap adoption checks, PDBs, and
   rolling control-plane convergence.

## Validation completed

- `go test ./...` passed.
- Load-test, autoscaling, Traefik, and Tempo configuration tests passed.
- `tofu -chdir=infra validate` passed.
- `opsctl verify-node-config` passed against K3s `v1.36.2+k3s1`.
- `opsctl verify-adoption` passed with its bootstrap-only environment values.
- `kubectl apply --dry-run=server -k kubernetes/overlays/prod` accepted the
  complete root graph.
- Generic kubeconform lacks Argo CD CRD schemas; that is a validator schema
  limitation, not a rejected live manifest.

## Live resource assessment

This assessment uses the Kubernetes metrics API for instantaneous usage and
VictoriaMetrics for seven-day history. Container series were deduplicated by
pod and container before aggregation because the metrics store has more than
one scrape path for some containers.

### Capacity and HA headroom

| Metric | Result |
|---|---:|
| Allocatable cluster CPU | 12 cores |
| Allocatable cluster memory | about 21.2 GiB |
| Current node CPU use | 7–11% per node |
| Seven-day maximum node CPU use | 22% per node |
| Current node memory use | 66–68% per node |
| Lowest seven-day `MemAvailable` | 2.75–3.11 GiB per node |
| Scheduled memory requests | 10.17 GiB, or about 48% of allocatable memory |
| Scheduled CPU requests | 1.82 cores, or about 15% of allocatable CPU |
| Per-node memory requests | 3.24–3.43 GiB |
| Pending Pods | none |

All scheduled requests can fit on two nodes: 10.17 GiB is below the roughly
14.2 GiB allocatable memory available after one node is lost. That proves
scheduler-level one-node recovery headroom, subject to normal PDB and
volume-attach timing. It does not prove that every workload can safely use its
historical maximum at the same instant after a failure.

Kubernetes schedules against requests, not current use. Requests therefore
need deliberate headroom for node drains and failures. See [Resource management
for Pods and containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/).

### Largest observed workloads

| Workload | Current memory | Seven-day p95 memory | Assessment |
|---|---:|---:|---|
| vmsingle | 1.04 GiB | 1.08 GiB | Keep its 4 GiB limit. The repository records an older 2.9 GiB peak. |
| Argo CD application controller | 661 MiB | 739 MiB | Keep. It manages 47 Applications. |
| Grafana | 397 MiB | 403 MiB | Keep. Dashboard and datasource sidecars add about 177 MiB. |
| arunanshu-dev, per Pod | 137–206 MiB | 317 MiB | Do not reduce the 384 MiB limit. |
| Traefik, per Pod | 41–45 MiB | 200 MiB | Keep HA replicas and current VPA guard. |
| vmagent | 138 MiB | 193 MiB | Keep its queue and 384 MiB limit. |
| Tempo | 100 MiB | 180 MiB | Keep the 1 GiB recovery ceiling; a past OOM and WAL recovery make seven days insufficient evidence to reduce it. |

### Workload decisions

**Keep.** Cilium, CoreDNS, Hetzner CCM and CSI, cert-manager, Sealed Secrets,
KEDA, Traefik, cloudflared, Velero, kured, system-upgrade-controller,
VictoriaMetrics, Tempo, and the VPA controller all provide a direct security,
HA, scheduling, recovery, or observability function. Their resource cost must
be assessed individually; removing any of them would weaken a stated cluster
invariant.

**Do not reduce replicas merely to save memory.** Three cloudflared replicas
cost about 70 MiB total and preserve edge connectivity across a node loss. The
two-replica controller pairs cost little and avoid a single controller outage.
Three Hetzner CCM replicas are more than the minimum needed for one-node
tolerance, but reducing them saves only tens of MiB and is not worthwhile
unless a strict two-replica control policy is adopted.

**Optional, not required.** Headlamp is an administrator convenience workload
at about 21 MiB. Hubble UI plus Relay are a network-debugging convenience at
about 100 MiB. Remove either only if the equivalent command-line and
metrics-based incident workflow is acceptable.

**Unused and worth a policy decision.** No live PV uses the default
`local-path` StorageClass. The local-path provisioner is therefore the only
currently unused controller. Do not remove it for its small memory saving
(about 13–27 MiB) alone. First make the encrypted Hetzner StorageClass the
intentional default, then disable local storage if local, node-bound volumes
are prohibited. That is a HA and data-safety improvement, not a capacity fix.

**Complexity candidate.** VPA consumes about 119 MiB now and manages 26
targets. It is not currently an unjustified workload: it produces useful
requests for Cilium, Traefik, Argo CD, and stateful monitoring. If operational
complexity becomes the priority, replace only stable, low-variance controller
VPAs with measured static requests. Keep VPA for vmsingle, Tempo, Traefik, and
the application until longer-term measurements support removal.

**No runtime saving from the CRD-only kube-prometheus-stack change.** The
chart already runs no Prometheus-stack Pods. Its replacement with a dedicated
CRD chart is a GitOps and reconciliation simplification, not a resource-saving
change.

### Verdict

**Pass with concerns.** Resource use is not minimal, but it is appropriately
conservative for the stated security, high-availability, and observability
invariants. CPU has large headroom. Memory has enough scheduled headroom for a
single node failure, but not enough evidence to downsize nodes or reduce the
protective limits of vmsingle, Tempo, or the application. The only immediate
cleanup candidate is the unused local-path provisioner, after its default
StorageClass policy is changed safely.

## Open decisions

- Is the etcd recovery window 12 or 45 days?
- Is monitoring data loss acceptable after LUKS key rotation?
- Should cloudflared retain TCP/443 for optional update checks?
- Is HCP Terraform acceptable for state, or must state remain self-managed?
- A VPA updater warning mentions a VMagent target reference with no matching
  repository VPA. Confirm its source before treating it as a repository defect.
