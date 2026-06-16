# Cluster Audit — Remaining Items (2026-06-17)

Follow-up to the full-cluster review run on 2026-06-17 (waste + security +
reliability lenses, kubescape live scan, manual manifest review). **Tier 1
(11 cheap, high-confidence fixes) was applied and verified green** in commits
`a1def77` and `ca39949`. This doc tracks what was deliberately deferred:
Tiers 2–4, ranked by fix cost.

For the Tier 1 footgun lesson (Helm `cpu: null` to delete a chart-default
limit), see the project memory `helm-null-override-deletes-chart-default`.

Severity = impact if exploited/hit. Fix-cost = effort to remediate.

---

## Tier 2 — SMALL (few lines / one file, low risk)

### [SEC-CRITICAL] Headlamp ServiceAccount bound to cluster-admin
- **Where:** `kubernetes/base/platform/headlamp/values.yaml` (chart default
  ClusterRoleBinding → `cluster-admin`; verified live)
- **Risk:** Single-replica UI behind only Cloudflare Access OTP. A session
  hijack, CF Access bypass, or a Headlamp CVE yields a cluster-admin token =
  full cluster compromise. Highest-value cheap fix.
- **Fix:** Override the chart's `clusterRoleBinding` to a custom **read-only**
  ClusterRole (get/list/watch); add hardened `securityContext`
  (`allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`,
  `capabilities.drop: [ALL]`). Add write verbs back selectively if needed.
- **Long term:** OIDC with short-lived tokens instead of the mounted SA token
  (needs k3s OIDC flags — see memory `headlamp-auth-decision`).

### [SEC-HIGH] Velero unhardened + cluster-admin
- **Where:** `kubernetes/base/platform/velero/values.yaml` (live container
  `securityContext: {}`; holds cluster-admin, reads every Secret)
- **Fix:** Add `containerSecurityContext` (`runAsNonRoot: true`,
  `runAsUser: 65532`, `readOnlyRootFilesystem: true`, `capabilities.drop:
  [ALL]`, `allowPrivilegeEscalation: false`). Verify the velero-restore-drill
  job (needs kubectl) still works.

### [SEC-HIGH] `terraform.tfvars` committed with account/zone IDs + email
- **Where:** `infra/terraform.tfvars:1-3` (CF account ID, zone ID,
  `owner_email`); the account ID is also in `velero/values.yaml` `s3Url`
- **Fix:** Move these into a gitignored `*.auto.tfvars` (add `*.tfvars` to
  `.gitignore`) or SOPS. API tokens are already SOPS-encrypted — only IDs/email
  leak here. Already in git history, so rotation is the only full remediation;
  removing stops future exposure.

### [WASTE-CONFIG] Dead `release: kube-prometheus-stack` labels
- **Where:** `kubernetes/components/hcloud-csi/values.yaml:80`,
  `hcloud-ccm/values.yaml:21`, `kured/values.yaml:35`
- **Why waste:** That Prometheus is gone (`prometheus.enabled: false`); the VM
  operator auto-converts all ServiceMonitor/PodMonitor objects regardless of
  label. Labels + their comments are dead.
- **Fix:** Remove the labels and the stale "kube-prometheus-stack is deployed"
  comments (3 files).

### [REL-HIGH] VPA-drift OOM window on traefik / cloudflared
- **Where:** `kubernetes/base/platform/traefik/values.yaml`
  (`limits.memory: 128Mi`) vs `components/traefik-scaling/resources/vpa.yaml`
  (`maxAllowed.memory: 256Mi`); same gap for cloudflared (64Mi vs 128Mi)
- **Risk:** On KEDA scale-out or pod replacement, a fresh pod starts at the
  lower static limit. If real usage exceeds it before VPA re-resizes, OOMKill.
- **Fix:** Set static `limits.memory` = VPA `maxAllowed.memory` so VPA in-place
  resize is idempotent (lands at the ceiling it already set).

---

## Tier 3 — MEDIUM (multi-file / needs verification or testing)

### [SEC-HIGH] AppProject `clusterResourceWhitelist: {group: "*", kind: "*"}`
- **Where:** `kubernetes/base/infra/appproject.yaml:35-37`,
  `base/monitoring/appproject.yaml:35-37`, `base/platform/appproject.yaml:50-52`
- **Risk:** Any repo in `sourceRepos` (public Helm repos) could push a
  ClusterRoleBinding granting cluster-admin and ArgoCD auto-applies it.
- **Fix:** Scope each project to the cluster-scoped kinds it actually deploys
  (CRD, ClusterRole, ClusterRoleBinding, Namespace, StorageClass…). The `apps`
  project's `Namespace`-only whitelist is the model. Requires auditing what
  each project deploys cluster-scoped.

### [SEC-HIGH] No API server audit logging
- **Where:** `infra/locals.tf` k3s config (no `audit-log-*` flags)
- **Risk:** Zero forensic trail on Secret reads, exec, token use. A compromised
  SA token (headlamp/velero/argocd) leaves no trace.
- **Fix:** Add `kube-apiserver-arg` audit flags + a minimal audit policy file
  via cloud-init. Requires a rolling control-plane restart.

### [SEC-HIGH] Monitoring UIs without app-level auth
- **Where:** `base/monitoring/prometheus-route/…` (VictoriaMetrics, exposes
  `/-/reload`, series delete), `components/hubble-route/…` (Hubble UI)
- **Risk:** Only CF Access OTP gates them; a bypassed session reaches
  destructive VM endpoints / full flow visibility.
- **Fix:** Disable VM destructive endpoints; reconsider exposing Hubble UI
  externally (operator-only tool); add Traefik BasicAuth as defense-in-depth.

### [WASTE-APP] Swap neutered kube-prometheus-stack → `prometheus-operator-crds`
- **Where:** `kubernetes/base/monitoring/kube-prometheus-stack/` (values.yaml:15
  already flags this as the planned follow-up)
- **Why waste:** The neutered chart reconciles ~200 resources only to deliver a
  handful of CRDs; `prometheus-operator-crds` delivers the same at ~10% surface.
  The VM stack has settled.
- **Fix:** Swap chart + repo, **verify CRD parity before prune**. Medium-risk,
  well-scoped.

### [SEC-MEDIUM] etcd-snapshot-health runs as root
- **Where:** `components/etcd-snapshot-health/resources/cronjob.yaml:18-20`
  (documented: `amazon/aws-cli` crashes under non-root)
- **Mitigated by:** caps dropped, seccompProfile, read-only S3 listing.
- **Fix:** Swap to a non-root image (`rclone/rclone`) or annotate the root
  requirement as explicitly accepted.

---

## Tier 4 — LARGE (design work)

### [SEC-CRITICAL] `policyAuditMode: true` — all NetworkPolicies unenforced
- **Where:** `kubernetes/base/infra/cilium/values.yaml:59`
- **Risk:** The single biggest *real* gap. The one CiliumNetworkPolicy
  (cloudflared) and every namespace are in audit mode — any pod can reach any
  service (argocd-redis, VM write API, tempo ingest, sealed-secrets). SSRF from
  the Next.js app traverses the cluster unrestricted.
- **Fix:** Use Hubble to enumerate per-namespace flows → author default-deny
  ingress+egress CiliumNetworkPolicies per namespace → flip `policyAuditMode:
  false` only after confirming no legitimate traffic drops. Replicate the
  cloudflared policy pattern. (Also neutralizes the in-cluster exposure half of
  the Tier 3 monitoring-UI item.)

### [SEC-MEDIUM] No admission policy controller
- **Where:** cluster-wide (no Kyverno/OPA/Gatekeeper)
- **Risk:** No enforced security floor; any new Helm chart can deploy a
  privileged/hostPath/limitless container. Supply-chain compromise has no
  backstop.
- **Fix:** Deploy Kyverno in audit→enforce with a minimal baseline policy set;
  use `PolicyException` for known-privileged components (kured, cilium,
  node-exporter, hcloud-csi).

---

## Non-findings / accepted (do not re-flag)

- **system-upgrade `channel: stable`** auto-upgrades — *documented deliberate
  choice* in `system-upgrade-plans/plans/k3s-server.yaml` with pin instructions.
  Risk-acceptance, not a bug.
- **ArgoCD `server.insecure: true`** — acceptable; WireGuard encrypts the
  node-to-node leg, TLS terminates at Cloudflare.
- **Privileged / hostPath / hostNetwork** on cilium, kured, node-exporter,
  hcloud-csi — required for those components; not actionable.
- **kubescape manifest scan = 97%** is misleading (overlay is only ArgoCD CRs);
  the **live scan = 63%** is the real number. Most failed controls are the
  required-privileged components above.
