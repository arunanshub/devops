# Backup and Restore

Two independent backup systems protect this cluster. They cover different failure domains and have different restore paths.

| System | What it protects | Cadence | Storage |
|--------|-----------------|---------|---------|
| k3s etcd snapshots | Cluster state (all Kubernetes objects, etcd data) | Every 6h | R2: `arunanshu-etcd-snapshots` |
| Velero | Kubernetes object metadata (no PV data) | Daily 02:00 UTC | R2: `arunanshu-velero-backups` |

**PV data (Prometheus metrics, Grafana data, Tempo traces) is deliberately not backed up.** These are acceptable-loss workloads. On a full rebuild they start fresh.

```
k3s (all 3 CP nodes)
  └─ every 6h ──► etcd snapshot (compressed) ──► R2: arunanshu-etcd-snapshots/prod/
                                                      ▲
etcd-snapshot-health CronJob (kube-system, every 8h) ─┘ checks recency → alert if stale

Velero controller (velero ns, daily 02:00 UTC)
  └─ full backup ──► R2: arunanshu-velero-backups/
       └─ metrics ──► ServiceMonitor ──► Prometheus ──► alerts

velero-restore-drill CronJob (velero ns, 1st of month 08:00 UTC)
  └─ restores monitoring → velero-restore-test → asserts Completed + zero warnings/errors → exit 0/1

Prometheus ──► PrometheusRules ──► Alertmanager ──► email (mydellpc07@gmail.com)
```

---

## etcd Snapshots

### How it works

k3s has built-in etcd snapshot support. When configured, it:
- Snapshots etcd every N hours (currently 6h, cron `0 */6 * * *`)
- Keeps 24 snapshots locally on each CP node
- Uploads compressed snapshots to R2, keeps 48 there (≈12 days at 6h cadence)
- R2 lifecycle also deletes any leftover objects after 45 days and aborts stale multipart uploads after 7 days
- Reads S3 credentials from a Kubernetes Secret of type `etcd.k3s.cattle.io/s3-config-secret`

The config lives on each CP node at `/etc/rancher/k3s/config.yaml.d/etcd-snapshots.yaml`.

### Configuration files

| File | What it does |
|------|-------------|
| `nodes/control-plane/etc/rancher/k3s/config.yaml.d/etcd-snapshots.yaml` | The declarative drop-in (applied by `just ansible-converge k3s-config`) |
| `kubernetes/components/etcd-snapshot-health/resources/sealedsecret-etcd-s3.yaml` | S3 credentials as SealedSecret |
| `kubernetes/components/etcd-snapshot-health/resources/cronjob.yaml` | Health check CronJob |

The drop-in config:

```yaml
etcd-s3: true
etcd-s3-config-secret: k3s-etcd-snapshot-s3-config
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 24   # local snapshots per node
etcd-s3-retention: 48         # snapshots in R2
etcd-snapshot-compress: true
```

### Reconfigure etcd snapshot schedule

1. Edit `nodes/control-plane/etc/rancher/k3s/config.yaml.d/etcd-snapshots.yaml` — change `etcd-snapshot-schedule-cron` (CI schema-validates the key against the pinned k3s binary).
2. If you increased the interval past ~8h, also update `MAX_AGE` in `kubernetes/components/etcd-snapshot-health/resources/cronjob.yaml` and the `> 36000` threshold in `kubernetes/base/monitoring/backup-alerts/resources/prometheusrule.yaml`.
   - Rule: `MAX_AGE = interval_seconds * 1.5`
3. Review with `just ansible-check k3s-config`, then `just ansible-converge k3s-config` to push the new config and restart k3s (serial, gated, auto-rolled-back on failure).

### Reconfigure retention

Same files. `etcd-snapshot-retention` = local count. `etcd-s3-retention` = R2 count. Defaults: 24 local, 48 R2. If retention must exceed 45 days, also update the `cloudflare_r2_bucket_lifecycle.etcd_snapshots` rule in `infra/cloudflare.tf`.

---

## Velero

### How it works

Velero runs as a Deployment in the `velero` namespace. It backs up Kubernetes API objects to R2 on a schedule. It does **not** back up PV data (nodeAgent is disabled).

- Daily full backup at 02:00 UTC: all namespaces + cluster resources, 30-day TTL
- R2 lifecycle deletes any leftover objects after 45 days and aborts stale multipart uploads after 7 days
- Credentials come from a `velero-r2-credentials` Secret (SealedSecret, `velero` namespace)
- BSL (BackupStorageLocation) `default` points at `arunanshu-velero-backups` on R2

### Configuration files

| File | What it does |
|------|-------------|
| `kubernetes/base/platform/velero/application.yaml` | ArgoCD Application, sync-wave 2 |
| `kubernetes/base/platform/velero/values.yaml` | Helm values: BSL config, schedule, metrics |
| `kubernetes/components/velero-restore-drill/resources/sealedsecret-velero-r2.yaml` | R2 credentials as SealedSecret |

### Reconfigure Velero backup schedule

Edit `kubernetes/base/platform/velero/values.yaml`:

```yaml
schedules:
  daily-full:
    schedule: "0 2 * * *"   # change this
    template:
      ttl: 720h              # retention (30 days)
```

Commit and let ArgoCD reconcile. No restarts needed — Velero watches its own Schedule CRs.

### Reconfigure backup retention

Change `ttl` in `schedules.daily-full.template.ttl`. Velero auto-expires old backups when they exceed TTL. If TTL must exceed 45 days, also update the `cloudflare_r2_bucket_lifecycle.velero_backups` rule in `infra/cloudflare.tf`.

---

## Health Monitoring

### Two CronJobs

**etcd-snapshot-health** (kube-system, every 8h):
- Lists `s3://arunanshu-etcd-snapshots/prod/`
- Finds the most recent object, checks its age
- Exits 0 if age < 10h, exits 1 if stale
- `kube_cronjob_status_last_successful_time` feeds the `EtcdSnapshotStale` alert

**velero-restore-drill** (velero, 1st of month 08:00 UTC):
- Finds the latest `Completed` daily-full backup
- Restores the `monitoring` namespace into `velero-restore-test`
- Excludes generated/runtime resources that should be recreated by controllers
- Asserts phase == `Completed`, warnings == 0, errors == 0, and restored count matches total count when Velero reports progress
- Cleans up and exits 0
- `kube_cronjob_status_last_successful_time` feeds the `VeleroRestoreDrillMissed` alert

### Alerts

All route to `mydellpc07@gmail.com` via Alertmanager.

| Alert | Fires when | Severity |
|-------|-----------|----------|
| `EtcdSnapshotStale` | etcd-snapshot-health hasn't succeeded in >10h | warning |
| `VeleroBackupMissed` | No successful backup for a schedule in >25h | warning |
| `VeleroBackupFailed` | Any backup failure in the last 2h | critical |
| `VeleroBSLUnavailable` | BSL `default` unreachable for >10min | critical |
| `VeleroRestoreDrillMissed` | No successful drill in >31 days | warning |

### Grafana dashboard

`just launch-grafana` → Dashboards → search "backup". Shows last backup time, backup count over 7 days, BSL status, etcd health last run, restore drill last run.

---

## Validate Backups (Day-to-Day)

```bash
# Quick status — backups, restores, BSL availability
just velero-status

# Are snapshots actually in R2?
kubectl create job --from=cronjob/etcd-snapshot-health etcd-health-$(date +%s) -n kube-system
kubectl logs -n kube-system job/etcd-health-<name> -f

# Run a Velero restore drill right now
kubectl create job --from=cronjob/velero-restore-drill drill-$(date +%s) -n velero
kubectl logs -n velero job/drill-<name> -f
# Should end with: "Restore drill succeeded"

# Check Velero BSL status directly
kubectl exec -n velero deploy/velero -- /velero backup-location get
# STATUS column should show: Available
```

---

## Restore Runbook

### Scenario 1 — Namespace or resource loss (30 min)

Use when: a namespace was accidentally deleted, data corrupted, need to recover specific resources. Cluster is running.

```bash
# 1. Find available backups
just velero-status

# 2. Disable ArgoCD auto-sync on the target namespace FIRST
#    (or ArgoCD will overwrite what you just restored)
kubectl patch application <app-name> -n argocd \
  --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'

# 3. Restore
just velero-restore <backup-name> <namespace>
# The recipe will prompt you to confirm auto-sync is disabled

# 4. Verify the restored state looks correct

# 5. Re-enable auto-sync
kubectl patch application <app-name> -n argocd \
  --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
# ArgoCD will reconcile any diff between restored state and git — this is expected
```

### Scenario 2 — Full cluster rebuild (45 min)

Use when: entire cluster is gone or unrecoverable. This is the GitOps path — no backup needed for cluster config because it's all in git.

```bash
# 1. Provision new nodes
just apply

# 2. Bootstrap
just argocd-bootstrap
just argocd-ssh-bootstrap
just restore-sealed-secrets-key   # CRITICAL — do this before argocd-root-bootstrap
just argocd-root-bootstrap

# 3. ArgoCD reconciles everything from git (~15-20 min)
kubectl get applications -n argocd

# 4. Optional: restore any dynamic state not in git (operator-created CRs, etc.)
just velero-restore <latest-backup> <namespace>
```

See `docs/bootstrap-pitfalls.md` for things that go wrong in step 2.

### Scenario 3 — etcd restore (last resort, 60+ min)

Use when: etcd is corrupted, cluster is in split-brain, or you need to roll back cluster state. This is destructive — the cluster will restart from the snapshot point.

```bash
just etcd-restore
# Prints the full procedure. Steps summarized below.
```

**Step-by-step:**

1. **List snapshots in R2** (apiserver may be down, use credentials directly):
   ```bash
   AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret> \
   aws s3 ls s3://arunanshu-etcd-snapshots/prod/ \
     --endpoint-url https://<account_id>.r2.cloudflarestorage.com \
     --region auto \
     | sort -k1,2 | tail -10
   ```

2. **Download the snapshot** to the target CP node:
   ```bash
   AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret> \
   aws s3 cp s3://arunanshu-etcd-snapshots/prod/<snapshot-name> /tmp/snapshot.db \
     --endpoint-url https://<account_id>.r2.cloudflarestorage.com --region auto
   ```

3. **Stop k3s on ALL nodes**:
   ```bash
   sops exec-env infra/secrets.yaml \
     'uv run ansible all -i ansible/inventory/hcloud.yml \
     -m service -a "name=k3s state=stopped" --become'
   ```

4. **Reset etcd on ONE CP node** (e.g. cp-0):
   ```bash
   k3s server --cluster-reset --cluster-reset-restore-path=/tmp/snapshot.db
   # Exits when done — that is expected
   ```

5. **Start k3s on the reset node first**, wait for it to be Ready:
   ```bash
   systemctl start k3s
   kubectl get nodes
   ```

6. **Start k3s on remaining CP nodes** one at a time:
   ```bash
   systemctl start k3s
   ```

**Why you must not pass credentials from the Secret:** The apiserver is down during etcd restore. The SealedSecrets controller is also down. The `k3s-etcd-snapshot-s3-config` Secret cannot be read. Credentials must be passed directly via environment variables or CLI flags.

**Where are the credentials?** In `infra/secrets.yaml` (SOPS-encrypted). To decrypt:
```bash
sops exec-env infra/secrets.yaml 'echo $R2_ETCD_ACCESS_KEY $R2_ETCD_SECRET_KEY $R2_ACCOUNT_ID'
```

---

## Secrets — Where Things Live

| Secret | Namespace | Contains | How to reseal |
|--------|-----------|---------|---------------|
| `k3s-etcd-snapshot-s3-config` | kube-system | R2 endpoint, access key, secret key for etcd bucket | `just seal-etcd-s3` |
| `velero-r2-credentials` | velero | AWS-format credentials for velero bucket | `just seal-velero-s3` |

Both are SealedSecrets reconciled by ArgoCD. The plaintext credentials source of truth is `infra/secrets.yaml` (SOPS-encrypted, keys: `R2_ETCD_ACCESS_KEY`, `R2_ETCD_SECRET_KEY`, `R2_VELERO_ACCESS_KEY`, `R2_VELERO_SECRET_KEY`, `R2_ACCOUNT_ID`).

To reseal after rotating R2 credentials:

```bash
# Update infra/secrets.yaml with new values, then:
just seal-etcd-s3
just seal-velero-s3
# Commit the new sealed secrets; ArgoCD applies them; pods pick up the change on next restart
```

---

## Gotchas (Hard-Won)

**etcd-s3-endpoint must be bare hostname, no https://**
The minio Go client used by k3s expects `<account_id>.r2.cloudflarestorage.com`, not `https://...`. Adding the scheme gives `"Endpoint url cannot have fully qualified paths"`. The scheme is controlled by `etcd-s3-insecure: "false"` in the Secret.

**amazon/aws-cli image requires root**
The `etcd-snapshot-health` CronJob has no `runAsUser` or `runAsNonRoot` in its securityContext. If you add them (e.g. `runAsUser: 1000`), Python's `pwd.getpwuid()` crashes silently (no `/etc/passwd` entry for UID 1000) and the container exits 1 with no logs.

**Restore namespace cleanup is bounded**
The `monitoring` namespace contains PVCs, and namespace deletion can wait on finalizers. The restore drill starts cleanup with `--wait=false`, then polls for the ephemeral `velero-restore-test` namespace to disappear before creating the next Restore. If cleanup still has not completed after 10 minutes, the drill fails instead of restoring into a dirty namespace.

**Velero sync-wave must be 2, not 0**
The `velero-r2-credentials` SealedSecret is deployed by the `velero-restore-drill` component at sync-wave 1. If Velero is at wave 0, it syncs before the credential exists and the BSL fails validation on first sync. Never move Velero back to wave 0.

**Velero BSL metric name**
The metric is `velero_backup_location_status_gauge{backup_location_name="default"}` — not `velero_backup_storage_location_available`. If you're writing PromQL against Velero, check `kubectl exec -n velero deploy/velero -- /velero --help` or look at `:8085/metrics` directly.

**R2 requires checksumAlgorithm: ""**
The velero-plugin-for-aws sends AWS checksum headers that R2 rejects. Setting `checksumAlgorithm: ""` in the BSL config disables them. Without it, all backups fail with a 400 error.

**R2 lifecycle resources are create/update only in the Cloudflare provider**
`cloudflare_r2_bucket_lifecycle` can create and update lifecycle rules, but the provider warns that destroying the Terraform resource will not delete the rule from Cloudflare. If a lifecycle rule must be removed, delete it manually in Cloudflare after updating the code.

**velero-restore-drill RBAC needs watch on restores**
The drill script polls `kubectl get restore` in a loop — that's a watch under the hood. The ClusterRole must include `watch` on `velero.io/restores`, not just `get`. Missing `watch` produces `reflector.go` forbidden errors in the logs (the drill still succeeds but the logs are noisy).

**Run once with serial in Ansible**
`run_once: true` with `serial: 1` runs once per batch, not once per play. Use `when: inventory_hostname == ansible_play_hosts_all[0]` instead for "run this task only on the first host."
