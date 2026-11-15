# PV Encryption Design

Date: 2026-05-25

## Goal

Encrypt all hcloud-csi Persistent Volumes at rest for defense-in-depth. Primary threat: raw block device access by a Hetzner employee or datacenter attacker. Secondary benefit: cryptographic data remanence protection when volumes are deleted.

## Threat Model

**Protected against:**
- Reading a detached or deleted Hetzner volume in isolation — the LUKS passphrase is not on the volume itself.
- Data remanence after volume deletion — without the passphrase the ciphertext is unrecoverable.

**Residual risk:**
- The LUKS passphrase lives in a Kubernetes Secret stored in embedded etcd, replicated across all three control-plane OS disks. An attacker with access to any one control-plane OS disk *and* a data volume can extract the passphrase and decrypt the volume. For the stated threat model (defense-in-depth, not nation-state) this residual risk is acceptable.
- hcloud-csi hard-codes LUKS defaults (AES-XTS-plain64, 256-bit, SHA-256, argon2i). Customizable parameters are an open upstream issue (#1062) and not yet implemented. The defaults are cryptographically sound.

## Approach

hcloud-csi (already deployed at v2.21.1) has **native LUKS encryption support**. No additional CSI driver is required. A new `hcloud-volumes-encrypted` StorageClass is added alongside the existing `hcloud-volumes`. The only new node dependency is `cryptsetup`, installed via Ansible.

The `extraParameters` key in the hcloud-csi Helm chart `storageClasses` array (added in chart v2.13.0, confirmed in v2.21.1 schema) passes the secret reference directly into the StorageClass parameters.

## Repository Changes

### 1. Ansible — install `cryptsetup` on all nodes

Add to `ansible/roles/baseline/tasks/main.yml`:

```yaml
- name: Install cryptsetup
  ansible.builtin.apt:
    name: cryptsetup
    state: present
```

Run `ansible-playbook ansible/playbooks/baseline.yml` against all nodes before activating the encrypted StorageClass. Mounts will fail silently if `cryptsetup` is absent when a new encrypted PVC is first attached.

### 2. New component — `kubernetes/components/hcloud-luks-key/`

Follows the `hcloud-secret` component pattern. Deploys a SealedSecret named `hcloud-luks-key` in `kube-system`.

Structure:
```
kubernetes/components/hcloud-luks-key/
  kustomization.yaml          # kustomize Component
  application.yaml            # ArgoCD Application, project: infra
  resources/
    kustomization.yaml
    sealed-luks-key.yaml      # SealedSecret, namespace: kube-system
```

The Secret data must contain exactly one key:
```yaml
stringData:
  encryption-passphrase: <passphrase>
```

Seal with `kubeseal` before committing. The passphrase should also be stored in a password manager — it is a first-class recovery artifact. If the SOPS→sealed-secrets chain is unavailable and the passphrase is lost, data on encrypted volumes is unrecoverable.

Add the component to `kubernetes/overlays/prod/kustomization.yaml`.

### 3. hcloud-csi values — add encrypted StorageClass

In `kubernetes/components/hcloud-csi/values.yaml`, add a second entry to `storageClasses`:

```yaml
storageClasses:
  - name: hcloud-volumes
    defaultStorageClass: false
    reclaimPolicy: Delete
    volumeBindingMode: WaitForFirstConsumer
    allowVolumeExpansion: true
  - name: hcloud-volumes-encrypted
    defaultStorageClass: false
    reclaimPolicy: Delete
    volumeBindingMode: WaitForFirstConsumer
    allowVolumeExpansion: true
    extraParameters:
      csi.storage.k8s.io/node-publish-secret-name: hcloud-luks-key
      csi.storage.k8s.io/node-publish-secret-namespace: kube-system
```

All PVCs provisioned from `hcloud-volumes-encrypted` share the same passphrase. Per-workload key isolation can be achieved later by creating additional StorageClasses pointing at different Secrets.

## Migration Plan

Migration is phased. Phase 1 is purely additive. Phases 2 and 3 require brief ArgoCD maintenance windows.

### Phase 1 — Infrastructure (no workload impact)

1. Add `cryptsetup` to Ansible baseline role.
2. Run `ansible-playbook ansible/playbooks/baseline.yml` across all nodes.
3. Create `hcloud-luks-key` SealedSecret component and add to overlay.
4. Add `hcloud-volumes-encrypted` StorageClass to hcloud-csi values.
5. Commit and push. ArgoCD reconciles: the SealedSecret and new StorageClass appear. Existing PVCs are untouched.
6. Verify: `kubectl get storageclass hcloud-volumes-encrypted` exists; `kubectl get secret hcloud-luks-key -n kube-system` exists.

### Phase 2 — Non-Prometheus workloads (data loss acceptable)

Affected workloads: **Grafana** (Deployment), **Alertmanager** (StatefulSet via Prometheus Operator), **Tempo** (StatefulSet).

**Important:** `storageClassName` is immutable on both PVCs and StatefulSet `volumeClaimTemplates`. ArgoCD cannot patch these in-place. Each workload requires a manual deletion step.

#### Grafana

Grafana is a Deployment with a standalone PVC (`hcloud-volumes`, 10Gi, namespace `monitoring`).

1. Update `storageClassName: hcloud-volumes-encrypted` in `kube-prometheus-stack/values.yaml` under `grafana.persistence`. Commit and push.
2. ArgoCD syncs, attempts to patch the PVC — fails silently (the PVC spec is immutable). The Application goes OutOfSync on that resource.
3. Manually delete the old PVC: `kubectl delete pvc -n monitoring -l app.kubernetes.io/name=grafana` (verify the label selector first with `kubectl get pvc -n monitoring`).
4. ArgoCD next sync creates a new PVC with `hcloud-volumes-encrypted`. Grafana pod restarts and reattaches.

#### Alertmanager

Alertmanager is a StatefulSet managed by the Prometheus Operator. Its `volumeClaimTemplate` is immutable.

PVC name: `alertmanager-kube-prometheus-stack-alertmanager-db-alertmanager-kube-prometheus-stack-alertmanager-0`

1. Update `storageClassName: hcloud-volumes-encrypted` in `kube-prometheus-stack/values.yaml` under `alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec`. Commit and push.
2. Disable ArgoCD auto-sync for `kube-prometheus-stack`:
   ```bash
   argocd app set kube-prometheus-stack --sync-policy none
   ```
3. Scale Alertmanager to 0:
   ```bash
   kubectl scale statefulset alertmanager-kube-prometheus-stack-alertmanager \
     -n monitoring --replicas=0
   ```
4. Delete the StatefulSet (not the PVC):
   ```bash
   kubectl delete statefulset alertmanager-kube-prometheus-stack-alertmanager \
     -n monitoring
   ```
5. Delete the old PVC:
   ```bash
   kubectl delete pvc alertmanager-db-alertmanager-kube-prometheus-stack-alertmanager-0 \
     -n monitoring
   ```
6. Re-enable auto-sync and trigger a sync:
   ```bash
   argocd app set kube-prometheus-stack \
     --sync-policy automated --self-heal --auto-prune
   argocd app sync kube-prometheus-stack
   ```
7. The Prometheus Operator recreates the StatefulSet; a new encrypted PVC is provisioned.

#### Tempo

Tempo is a StatefulSet with `releaseName: tempo`, `fullnameOverride: tempo`.

Confirm the PVC name before running: `kubectl get pvc -n monitoring -l app.kubernetes.io/name=tempo`

1. Update `storageClassName: hcloud-volumes-encrypted` in `tempo/values.yaml` under `persistence.storageClassName`. Commit and push.
2. Disable ArgoCD auto-sync for `tempo`:
   ```bash
   argocd app set tempo --sync-policy none
   ```
3. Delete the Tempo StatefulSet:
   ```bash
   kubectl delete statefulset tempo -n monitoring
   ```
4. Delete the old PVC (use the name confirmed above).
5. Re-enable auto-sync:
   ```bash
   argocd app set tempo --sync-policy automated --self-heal --auto-prune
   argocd app sync tempo
   ```

### Phase 3 — Prometheus (data preserved, 14d retention worth keeping)

Prometheus is a StatefulSet managed by the Prometheus Operator.

- StatefulSet name: `prometheus-kube-prometheus-stack-prometheus`
- PVC name: `prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0`
- Namespace: `monitoring`

The strategy is: rsync the bulk of TSDB data live (TSDB blocks are immutable once written), then do a final incremental sync after scaling to 0, then use the PV retain-and-rebind technique to rename the encrypted PVC to the name the new StatefulSet expects.

#### Step-by-step

**1. Create a temporary encrypted PVC (cluster still running normally)**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: prometheus-migration-temp
  namespace: monitoring
spec:
  storageClassName: hcloud-volumes-encrypted
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
```

```bash
kubectl apply -f /tmp/prometheus-migration-temp-pvc.yaml
```

**2. Bulk rsync while Prometheus is still running**

```yaml
# /tmp/prometheus-migration-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: prometheus-migration
  namespace: monitoring
spec:
  restartPolicy: Never
  containers:
    - name: rsync
      image: alpine:3.21
      command: [sh, -c, "apk add rsync && rsync -aH --info=progress2 /old/ /new/"]
      volumeMounts:
        - name: old
          mountPath: /old
          readOnly: true
        - name: new
          mountPath: /new
  volumes:
    - name: old
      persistentVolumeClaim:
        claimName: prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
    - name: new
      persistentVolumeClaim:
        claimName: prometheus-migration-temp
```

```bash
kubectl apply -f /tmp/prometheus-migration-pod.yaml
kubectl logs -n monitoring prometheus-migration -f
kubectl delete pod -n monitoring prometheus-migration
```

**3. Protect the encrypted PV from deletion**

Get the PV name backing the temp PVC and set its reclaim policy to `Retain` so that deleting the PVC later does not delete the underlying Hetzner volume:

```bash
TEMP_PV=$(kubectl get pvc prometheus-migration-temp -n monitoring \
  -o jsonpath='{.spec.volumeName}')

kubectl patch pv "$TEMP_PV" \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

**4. Disable ArgoCD auto-sync and scale Prometheus to 0**

```bash
argocd app set kube-prometheus-stack --sync-policy none

kubectl scale statefulset prometheus-kube-prometheus-stack-prometheus \
  -n monitoring --replicas=0

# Wait for pod to terminate
kubectl wait pod -n monitoring \
  -l app.kubernetes.io/name=prometheus --for=delete --timeout=120s
```

**5. Final incremental rsync (catches recently compacted/deleted TSDB blocks)**

```bash
kubectl apply -f /tmp/prometheus-migration-pod.yaml  # same pod spec as step 2
# but with --delete flag added to rsync args:
# rsync -aH --delete --info=progress2 /old/ /new/
kubectl logs -n monitoring prometheus-migration -f
kubectl delete pod -n monitoring prometheus-migration
```

Use `--delete` on this final pass so that any TSDB blocks compacted-and-removed since the bulk copy are also removed from the encrypted copy. This produces a consistent snapshot.

**6. Release the encrypted PV for rebinding**

```bash
# Delete the temp PVC — PV transitions to Released (Hetzner volume survives
# because reclaim policy is Retain)
kubectl delete pvc prometheus-migration-temp -n monitoring

# Clear the claimRef so the PV becomes Available again
kubectl patch pv "$TEMP_PV" --type=json \
  -p='[{"op":"remove","path":"/spec/claimRef"}]'

# Confirm
kubectl get pv "$TEMP_PV"  # should show STATUS=Available
```

**7. Delete old PVC and pre-create the final encrypted PVC**

This is the brief risk window. The encrypted PV and its data are safe throughout because reclaim policy is `Retain` — no data is lost regardless of what happens to the PVC objects.

```bash
# Delete the old unencrypted PVC first
kubectl delete pvc prometheus-db-prometheus-kube-prometheus-stack-prometheus-0 \
  -n monitoring

# Immediately create the new PVC with the same name, pre-bound to the encrypted PV
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
  namespace: monitoring
spec:
  storageClassName: hcloud-volumes-encrypted
  volumeName: $TEMP_PV
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
EOF
```

Confirm binding: `kubectl get pvc prometheus-db-prometheus-kube-prometheus-stack-prometheus-0 -n monitoring` — STATUS should be `Bound`.

**8. Remove the old StatefulSet and re-enable ArgoCD**

Update `storageClassName: hcloud-volumes-encrypted` in `kube-prometheus-stack/values.yaml` under `prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec`. Commit and push.

```bash
# Delete the StatefulSet (pods already scaled to 0, PVC is pre-created)
kubectl delete statefulset prometheus-kube-prometheus-stack-prometheus \
  -n monitoring

# Re-enable auto-sync — ArgoCD recreates the StatefulSet via Prometheus Operator
argocd app set kube-prometheus-stack \
  --sync-policy automated --self-heal --auto-prune
argocd app sync kube-prometheus-stack
```

The Prometheus Operator recreates the StatefulSet. It finds the pre-existing PVC by name and binds to it. Prometheus starts and loads historical TSDB data from the encrypted volume.

**9. Verify and clean up**

```bash
# Prometheus is running and has historical data
kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus
# Check TSDB head in Prometheus UI or via API:
# curl http://prometheus:9090/api/v1/status/tsdb

# Restore PV reclaim policy to Delete (matches StorageClass default)
kubectl patch pv "$TEMP_PV" \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'

# The old unencrypted PV was auto-reaped when the old PVC was deleted
# (reclaimPolicy was Delete). Verify no orphan PVs remain:
kubectl get pv | grep Released
```

## General PV Migration Runbook

For future stateful workloads where data matters, the pattern is:

**Deployments:**
1. Update `storageClassName` in values → commit.
2. Manually delete the old PVC (ArgoCD cannot patch it).
3. ArgoCD creates new PVC on next sync.

**StatefulSets (data loss acceptable):**
1. Update `storageClassName` in values → commit.
2. Disable ArgoCD auto-sync on the Application.
3. Delete the StatefulSet.
4. Delete the old PVC(s).
5. Re-enable auto-sync → controller recreates StatefulSet with new PVCs.

**StatefulSets (data preservation required):**
1. Create a temp PVC with the new StorageClass.
2. Run an `alpine` + `rsync` migration pod: bulk copy live (`rsync -aH`), final pass after scale-to-0 (`rsync -aH --delete`).
3. Patch temp PV reclaim policy → `Retain`.
4. Disable ArgoCD auto-sync; scale StatefulSet to 0.
5. Delete temp PVC → PV transitions to `Released`.
6. Clear PV `claimRef`: `kubectl patch pv $PV --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'`
7. Delete old PVC.
8. Create new PVC with `volumeName: $PV` to pre-bind the encrypted PV under the correct StatefulSet-expected name.
9. Update `storageClassName` in values → commit; delete old StatefulSet; re-enable auto-sync.
10. Restore PV reclaim policy → `Delete`.

## Files Changed

| File | Change |
|------|--------|
| `ansible/roles/baseline/tasks/main.yml` | Add `cryptsetup` package |
| `kubernetes/components/hcloud-luks-key/` | New component (SealedSecret + ArgoCD Application) |
| `kubernetes/overlays/prod/kustomization.yaml` | Add `hcloud-luks-key` component |
| `kubernetes/components/hcloud-csi/values.yaml` | Add `hcloud-volumes-encrypted` StorageClass |
| `kubernetes/base/monitoring/kube-prometheus-stack/values.yaml` | Update `storageClassName` × 3 (Grafana, Prometheus, Alertmanager) |
| `kubernetes/base/monitoring/tempo/values.yaml` | Update `storageClassName` |
