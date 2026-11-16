# SRE Reliability Audit - 2026-05-30

Staff-level reliability review of the Hetzner k3s cluster and its
infrastructure-as-code. The audit used the repository state plus live cluster
read-only checks through `infra/kubeconfig.yaml`.

## Scope

Reviewed:

- OpenTofu in `infra/`
- Ansible playbooks and inventory flow
- Kustomize/ArgoCD application graph under `kubernetes/`
- Live Kubernetes state: nodes, pods, PDBs, services, Gateway API, Cilium,
  NetworkPolicy, RBAC, VPA, storage, events, backups, and resource usage
- Networking path: Hetzner private network, Cilium VXLAN, WireGuard, PMTUD,
  Gateway API, cloudflared, Traefik, DNS, and firewall/LB boundaries
- Security posture: exposure paths, PSA labels, dashboard RBAC, service
  accounts, network policy, secrets flow, and backup credentials

Validation commands that passed during the audit:

```sh
tofu -chdir=infra fmt -check -diff
tofu -chdir=infra validate -no-color
kustomize build kubernetes/overlays/prod -o /tmp/arunanshu-k8s-rendered.yaml
kubectl apply --server-side --dry-run=server -f /tmp/arunanshu-k8s-rendered.yaml
just verify-mtu
for pb in baseline k3s-eviction k3s-etcd-snapshots site ops/recreate-encrypted-pvcs ops/migrate-prometheus-encrypted; do
  just _ansible-playbook "$pb" "--syntax-check"
done
```

## Follow-up Remediation Status

Applied live on 2026-05-30:

- CoreDNS now runs two ready replicas with a `maxUnavailable: 1` PDB via
  `ansible/playbooks/k3s-coredns-ha.yml`.
- Kubelet on all three nodes now uses `/etc/rancher/k3s/resolv.conf` via
  `ansible/playbooks/k3s-resolver.yml`, removing the resolver source that
  caused persistent `DNSConfigForming` warnings for new pods.
- Cloudflare R2 lifecycle rules now exist for both backup buckets: delete
  objects after 45 days and abort stale multipart uploads after 7 days.

Prepared in GitOps/IaC for the next commit and ArgoCD reconciliation:

- `just velero-status` and `just velero-restore` call `/velero`.
- The Velero restore drill fails on warnings/errors, waits for the old test
  namespace to disappear, and excludes generated/runtime resources.
- Cilium, Cilium operator, Cilium Envoy, hcloud CCM, hcloud CSI, and kured have
  explicit resource requests.
- cloudflared disables service account token automount and uses strict
  hostname topology spread.
- Traefik has strict hostname topology spread.
- The bootstrap-only k3s version was aligned to the live `v1.35.5+k3s1`.

System Upgrade Controller remains on the stable channel; it was not pinned.

Post-remediation validation that passed:

```sh
just ansible-converge k3s-coredns-ha
just ansible-converge k3s-resolver
kubectl get nodes
kubectl -n kube-system get deploy coredns
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
just verify-mtu
just velero-status
just plan
```

## Current Healthy Signals

- Three nodes are Ready, all are control-plane and etcd voters:
  `hetzner-k3s-cp-1`, `hetzner-k3s-cp-2`, `hetzner-k3s-cp-3`.
- Live node version is `v1.35.5+k3s1`; all nodes report no MemoryPressure,
  DiskPressure, or PIDPressure.
- ArgoCD reports all applications Synced and Healthy.
- Cilium reports OK for agents, operator, Envoy, and Hubble Relay.
- No pods were in non-Running/non-Succeeded phases during the audit.
- PDBs all allowed one disruption at the time checked.
- Public Kubernetes Services are not exposed directly; application exposure is
  via cloudflared to Traefik/Gateway API.
- MTU verification passed:
  - pod `eth0` MTU: 1450
  - cross-node 1280-byte payload: 0% loss
  - cross-node 1292-byte payload, 1320-byte packet ceiling: 0% loss
  - `cilium_wg0` MTU: 1370 on all nodes
  - Cilium PMTUD enabled with mode `always`
- etcd snapshot health is OK. Latest observed health job reported:
  `Latest snapshot age: 21598s (threshold: 36000s)`.
- Velero BackupStorageLocation `default` is Available, and recent scheduled
  backups on 2026-05-27 through 2026-05-30 completed.
- Monitoring PVCs are bound to `hcloud-volumes-encrypted`.

## Acknowledged And Deferred Risks

These are real risks, but they are explicitly accepted for now because they
support the current operating workflow.

### Cilium Policy Audit Mode

`kubernetes/base/infra/cilium/values.yaml` sets:

```yaml
policyAuditMode: true
```

Live Cilium config confirms `PolicyAuditMode: Enabled`, and the `cloudflared`
endpoint shows policy enforcement as `Disabled (Audit)` for both ingress and
egress.

Impact: the `cloudflared` CiliumNetworkPolicy is validating/logging but not
enforcing. If `cloudflared` is compromised, the intended egress allowlist does
not actually constrain it.

Deferred remediation:

- Set `policyAuditMode: false`.
- Sync Cilium.
- Verify `cilium-dbg endpoint list` shows policy enforcement enabled for
  `cloudflared`.
- Use Hubble to validate expected drops.

### Headlamp Cluster-Admin Exposure

Headlamp runs with `inCluster: true`, is reachable at
`headlamp.arunanshu.dev`, and the live `headlamp-admin` ClusterRoleBinding
binds `system:serviceaccount:headlamp:headlamp` to `cluster-admin`.

Impact: compromise of the Headlamp access path, session, or app gives full
cluster-admin power.

Current compensating control: manual short-lived access tokens.

Deferred remediation:

- Remove the public route or keep Headlamp disabled when not actively needed.
- Replace in-cluster cluster-admin auth with OIDC/RBAC.
- Use least-privilege roles and user impersonation if Headlamp supports the
  desired workflow.

### ArgoCD Built-In Admin

Live `argocd-cm` has `admin.enabled: "true"`, and ArgoCD is reachable at
`argocd.arunanshu.dev`.

Impact: ArgoCD is a high-privilege GitOps control plane exposed through the
Cloudflare Access path. Built-in admin should not be a permanent operating
model.

Current reason for deferral: admin is useful for forcing reconciliation.

Deferred remediation:

- Configure SSO/OIDC and explicit ArgoCD RBAC.
- Disable the built-in admin account.
- Keep a documented emergency break-glass path.

## Fixable Now

These items are good candidates for immediate remediation. They do not depend
on the deferred Headlamp/ArgoCD/Cilium-policy decisions.

### 1. Fix `just velero-status`

Current `Justfile` recipes run `velero` inside the Velero pod:

```sh
kubectl exec -n velero deploy/velero -- velero backup get
```

Live check failed because the binary is available as `/velero`, not on `PATH`.

Fix:

- Change `velero` to `/velero` in `velero-status`.
- Change `velero` to `/velero` in `velero-restore`.

Risk: low. This is a local operator tooling fix.

### 2. Make The Velero Restore Drill Stricter

The live restore drill `drill-20260524221852` completed with 5 warnings. The
CronJob currently treats `status.phase == Completed` as success and does not
inspect warnings.

Fix:

- Fail the drill if `.status.warnings` is non-zero.
- Consider failing if restored resource warnings include conflicts or skipped
  resources.
- Wait for the `velero-restore-test` namespace to fully disappear before
  starting a new restore. The current cleanup uses `--wait=false`, which can
  let a new drill race a terminating namespace.
- Consider excluding generated/runtime resources that are not useful proof of
  restore correctness.

Risk: low to medium. This may make the next drill fail, but that is useful
signal rather than a regression.

### 3. Add Stable Resource Requests For VPA `Off` System Components

Several infrastructure components intentionally have VPA in recommendation-only
mode. That is fine, but their recommendations should be periodically promoted
to chart values so the scheduler has realistic requests.

Observed examples:

| Component | VPA mode | Live recommendation |
| --- | --- | --- |
| Cilium agent | Off | 109m CPU, ~309Mi memory |
| Cilium operator | Off | 15m CPU, ~156Mi memory |
| Cilium Envoy | Off | 15m CPU, 100Mi memory |
| hcloud CCM | Off | 15m CPU, 100Mi memory |
| hcloud CSI controller | Off | 11m CPU, ~23Mi memory |
| hcloud CSI node | Off | 11m CPU, ~33Mi memory |
| kured | Off | 15m CPU, 100Mi memory |

Fix:

- Add explicit requests/limits in Helm values or manifests for Cilium,
  Cilium operator, Cilium Envoy, hcloud CCM, hcloud CSI, and kured.
- Keep VPA `Off` if those pods should not be mutated automatically.
- Use the current VPA recommendations as starting requests, with limits only
  where the component handles OOM risk safely.

Risk: medium. Needs chart-key care, especially for Cilium, but it is a good
resource reliability improvement.

### 4. Increase CoreDNS Availability

Live CoreDNS has one replica. The deployment has topology spread constraints,
but a single replica is still a DNS single point of failure during pod failure,
node drain, or image/runtime hiccups.

Fix options:

- Add a durable k3s-managed override for CoreDNS replicas.
- Alternatively, add a GitOps-owned patch if ownership with the k3s AddOn is
  clear and does not fight reconciliation.
- Target 2 replicas on this 3-node cluster, with a PDB that still permits
  one-at-a-time maintenance.

Risk: medium. The important part is choosing the ownership path so k3s and
GitOps do not fight each other.

### 5. Resolve `DNSConfigForming` Warnings

Recent events repeatedly showed:

```text
Nameserver limits were exceeded, some nameservers have been omitted
```

The kubelet config uses `/run/systemd/resolve/resolv.conf`, and pods receiving
that resolver file exceed Kubernetes nameserver limits.

Fix:

- Configure nodes so the resolver source used by kubelet contains no more than
  three upstream nameservers.
- Prefer doing this through Ansible so the setting survives replacement nodes.
- After changing, verify with events and kubelet `/configz`.

Risk: medium. DNS changes are easy to get subtly wrong; roll one node at a
time.

### 6. Disable Unneeded Service Account Tokens

`cloudflared` does not need Kubernetes API access. Live RBAC check for
`system:serviceaccount:cloudflared:default` returned `no` for broad pod access,
but the projected token is still unnecessary.

Fix:

- Add `automountServiceAccountToken: false` to the `cloudflared` pod spec.
- Review other non-controller workloads for the same hardening.

Risk: low.

### 7. Add Topology Spread Or Anti-Affinity For Edge Components

`cloudflared` has two replicas and a topology spread rule with
`whenUnsatisfiable: ScheduleAnyway`. Traefik has two replicas but no obvious
topology spread in the live deployment output.

Fix:

- Make `cloudflared` placement strict enough that both replicas do not land on
  one node when capacity allows.
- Add equivalent placement rules for Traefik.
- Keep PDBs compatible with one-node-at-a-time maintenance.

Risk: low to medium. On a 3-node cluster this is straightforward, but verify it
does not block scheduling during maintenance.

### 8. Align k3s Version Ownership

OpenTofu pins bootstrap nodes to `v1.35.4+k3s1`, while live nodes are
`v1.35.5+k3s1`. The System Upgrade Controller tracks the stable channel.

Fix options:

- Bump `infra/locals.tf` to the live tested version after upgrades complete.
- Or pin the System Upgrade Controller plan to an explicit tested version
  instead of the stable channel.

Risk: low if only bumping the bootstrap pin to current live version. Higher if
changing upgrade policy.

### 9. Clarify R2 Lifecycle And Versioning Ownership

`infra/cloudflare.tf` codifies the R2 buckets, while the backup plan documents
manual lifecycle and versioning steps in Cloudflare.

Fix:

- Verify whether lifecycle rules and versioning are actually configured in
  Cloudflare for both buckets.
- If provider support exists, codify them.
- If provider support is still missing, add a recurring manual verification
  checklist to the runbook.

Risk: low. This is mostly backup hygiene and drift prevention.

### 10. Revisit Monitoring Namespace PSA Split

`monitoring` enforces privileged PSA because node-exporter needs host access.
That also lets other monitoring workloads run under a privileged namespace
policy.

Fix:

- Move node-exporter to a dedicated privileged namespace, or use a more narrow
  exemption strategy.
- Return Grafana, Prometheus, Alertmanager, and Tempo to restricted or baseline
  enforcement.

Risk: medium. This touches kube-prometheus-stack wiring and ServiceMonitor
selection.

## Resource And Memory Notes

Live node usage during the audit:

| Node | CPU | Memory |
| --- | --- | --- |
| `hetzner-k3s-cp-1` | 369m, 9% | 4792Mi, 66% |
| `hetzner-k3s-cp-2` | 585m, 14% | 4584Mi, 63% |
| `hetzner-k3s-cp-3` | 191m, 4% | 4299Mi, 59% |

Largest live memory users observed:

| Workload/container | Memory |
| --- | --- |
| Prometheus | ~2008Mi |
| ArgoCD application-controller | ~619Mi |
| Tempo | ~227Mi |
| Grafana main container | ~201Mi |
| Cilium agents | ~146Mi to 226Mi |
| Cilium operators | ~115Mi to 122Mi |

Allocated memory requests were not dangerously high, but they are uneven:

| Node | Memory requests | Memory limits |
| --- | --- | --- |
| `hetzner-k3s-cp-1` | 33% | 68% |
| `hetzner-k3s-cp-2` | 60% | 74% |
| `hetzner-k3s-cp-3` | 36% | 81% |

Kubelet eviction thresholds are in place on all nodes:

```text
evictionHard: memory.available<500Mi,imagefs.available<5%,nodefs.available<5%
evictionSoft: memory.available<1Gi
```

The main resource action is not "add capacity now"; it is to turn VPA
recommendations for recommendation-only system pods into real requests.

## Networking Notes

The Cilium/VXLAN/WireGuard MTU design is currently behaving correctly.

Confirmed live Cilium config:

- `kube-proxy-replacement: true`
- `routing-mode: tunnel`
- `tunnel-protocol: vxlan`
- `enable-wireguard: true`
- `encrypt-node: true`
- `wireguard-persistent-keepalive: 25s`
- `enable-bpf-masquerade: true`
- `enable-pmtu-discovery: true`
- `packetization-layer-pmtud-mode: always`

Firewall and LB posture is sound:

- SSH is restricted to `home_ip`.
- Public API `6443` is restricted to `home_ip`.
- The API load balancer uses the private network and targets control-plane
  nodes with `use_private_ip = true`.
- ICMP is open for ping and PMTUD.

Main networking issues to fix now:

- DNS resolver limits causing `DNSConfigForming` warnings.
- Lack of enforced network isolation while Cilium audit mode is deferred.
- Placement hardening for cloudflared and Traefik.

## Backup And DR Notes

etcd snapshots look healthy. Velero is mostly healthy but should be tightened:

- BackupStorageLocation is Available.
- Recent daily backups completed.
- One older scheduled backup failed on 2026-05-26 with:
  `Header 'x-amz-tagging' with value '' not implemented`.
- The restore drill completed but had warnings.
- `just velero-status` currently fails because it calls `velero` instead of
  `/velero` inside the container.

Immediate work:

- Fix `just velero-status`.
- Make restore drills fail on warnings.
- Wait for test namespace deletion before restoring.
- Check whether the 2026-05-26 tagging failure was fixed by the current Velero
  values, especially `checksumAlgorithm: ""`, or whether another R2-specific
  setting is needed.

## Suggested Order Of Work

1. Fix `just velero-status` and `just velero-restore` to use `/velero`.
2. Harden cloudflared by disabling service account token automount.
3. Tighten the Velero restore drill checks.
4. Add static resource requests for VPA `Off` system components.
5. Decide and implement durable CoreDNS replica ownership.
6. Fix node DNS resolver configuration through Ansible.
7. Add strict placement for cloudflared and Traefik.
8. Align k3s bootstrap pin with the live version, or pin upgrade policy.
9. Verify R2 lifecycle/versioning and document or codify it.
10. Split node-exporter privilege away from the rest of monitoring.
