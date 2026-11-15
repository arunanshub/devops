# Cluster Audit — Remaining Items (2026-06-17)

Follow-up to the full-cluster review run on 2026-06-17 (waste + security +
reliability lenses, kubescape live scan, manual manifest review).

- **Tier 1** (11 cheap fixes) — DONE, verified green (`a1def77`, `ca39949`).
- **Tier 2** — DONE except #14 (`df431cc`, `c05f86d`); see status notes below.
- **Tiers 3–4** — still deferred, ranked by fix cost.

For footgun lessons see project memory: `helm-null-override-deletes-chart-default`
(Helm `cpu: null`), `vm-operator-converter-argocd-prune` (ArgoCD pruning converted
VM scrapes), `velero-runasnonroot-cnb-image` (buildpacks non-numeric USER).

Severity = impact if exploited/hit. Fix-cost = effort to remediate.

---

## Tier 2 — DONE except #14 (2026-06-17, commits `df431cc` + `c05f86d`)

### [SEC-CRITICAL] ✅ Headlamp ServiceAccount bound to cluster-admin — DONE
- `kubernetes/base/platform/headlamp/values.yaml`: bound to built-in read-only
  `view` role (excludes Secrets) + hardened securityContext (drop ALL, RO-rootfs,
  no-priv-esc). roleRef is immutable — ArgoCD auto-recreated the `headlamp-admin`
  CRB. Verified live: SA can read pods, **cannot** read Secrets / create / delete.
- **Known tradeoff:** `view` 403s the Nodes/PVs/CRDs pages in the UI. If richer
  read-only is wanted, swap in a custom aggregated read role (everything except
  Secrets). Long term: OIDC (see memory `headlamp-auth-decision`).

### [SEC-HIGH] ✅ Velero unhardened + cluster-admin — DONE
- `kubernetes/base/platform/velero/values.yaml`: `containerSecurityContext` with
  `allowPrivilegeEscalation: false` + `capabilities.drop: [ALL]`.
- **`runAsNonRoot` deliberately NOT set** — velero v1.18 is a buildpacks image
  with non-numeric USER (`cnb`) → `CreateContainerConfigError`. Image already runs
  non-root. **`readOnlyRootFilesystem` deferred** — backup scratch writes.
  See memory `velero-runasnonroot-cnb-image`.

### [SEC-HIGH] ⏳ `terraform.tfvars` committed with account/zone IDs + email — #14, NOT DONE
- **Where:** `infra/terraform.tfvars:1-3` (CF account ID, zone ID,
  `owner_email`); the account ID is also in `velero/values.yaml` `s3Url`
- **Fix:** Move these into a gitignored `*.auto.tfvars` (add `*.tfvars` to
  `.gitignore`) or SOPS. API tokens are already SOPS-encrypted — only IDs/email
  leak here. Already in git history, so rotation is the only full remediation;
  removing stops future exposure. **Deferred at user request.**

### [WASTE-CONFIG] ✅ Dead `release: kube-prometheus-stack` labels — ATTEMPTED, REVERTED
- Removing them was net-negative: the chart rendered `labels: null` and churned
  the ArgoCD diff. Kept the labels (harmless for selection — VMAgent uses
  `selectAllByDefault`). Lowest-value item; not worth the churn.

### [REL-HIGH] ✅ VPA-drift OOM window on traefik / cloudflared — DONE
- Raised static `limits.memory` to VPA `maxAllowed`: traefik 128→256Mi
  (`base/platform/traefik/values.yaml`), cloudflared 64→128Mi
  (`components/cloudflared/resources/deployment.yaml`). A fresh/scaled-out pod
  can no longer OOM before VPA in-place resizes it.

### Tier-2 sequel: a systemic latent bug surfaced and was fixed
Tier-2 syncs exposed that the **VM operator's prometheus-converter copies ArgoCD's
`tracking-id` annotation onto generated VMServiceScrape/VMPodScrape**, so ArgoCD
tried to prune those operator-owned objects (perpetual OutOfSync). Fixed at the
source: `victoria-metrics-operator.operator.prometheus_converter_add_argocd_ignore_annotations:
true` in the VM stack values → converted objects get `IgnoreExtraneous`. See memory
`vm-operator-converter-argocd-prune`.

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
