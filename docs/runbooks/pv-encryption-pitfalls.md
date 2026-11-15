# PV Encryption Pitfalls

Everything learned during the LUKS PV encryption migration. Every bug we hit, why it happened, and how to fix it. If something breaks at 3am, start here.

---

## Background: how the encryption works

hcloud-csi natively supports LUKS encryption. When a PVC is provisioned from `hcloud-volumes-encrypted`, the CSI node plugin runs `cryptsetup luksFormat` with the passphrase from a Kubernetes Secret, then formats the resulting device with ext4. Mount = `luksOpen`. No separate daemon. No extra CSI driver.

**The passphrase lives as a SealedSecret at:**
`kubernetes/components/hcloud-luks-key/resources/sealed-luks-key.yaml`

**Recovery chain if you ever need the plaintext passphrase:**
1. SOPS private key → decrypt `kubernetes/bootstrap/secrets/sealed-secrets-master-key.sops.yaml` → sealed-secrets private key
2. Use sealed-secrets private key to unseal `hcloud-luks-key` Secret in `kube-system`
3. `kubectl get secret hcloud-luks-key -n kube-system -o jsonpath='{.data.encryption-passphrase}' | base64 -d`

**Playbooks for ongoing ops:**
- `just ops-migrate-prometheus` — migrate Prometheus data to encrypted PVC (interactive, two checkpoints)
- `just ops-recreate-encrypted-pvcs` — rotate passphrase: delete and recreate Grafana/Alertmanager/Tempo PVCs
- `just rotate-luks-passphrase` — generate new passphrase, seal, commit, push (run before ops-recreate-encrypted-pvcs)

---

## Never echo the passphrase before piping to kubeseal

**Symptom.** Passphrase is visible in terminal output, chat logs, shell history.

**Cause.** `PASSPHRASE=$(openssl rand -base64 32) && echo "$PASSPHRASE" && ... | kubeseal`

**Fix.** Always pipe directly without echoing:

```bash
PASSPHRASE=$(openssl rand -base64 32)
kubectl create secret generic hcloud-luks-key \
  --namespace kube-system \
  --from-literal=encryption-passphrase="$PASSPHRASE" \
  --dry-run=client -o yaml | \
kubeseal --cert kubernetes/sealed-secrets-cert.pem --format yaml \
  > kubernetes/components/hcloud-luks-key/resources/sealed-luks-key.yaml
unset PASSPHRASE
```

**If you accidentally exposed a passphrase:** run `just rotate-luks-passphrase` immediately, then `just ops-recreate-encrypted-pvcs`. Old volumes carry the old passphrase in their LUKS header and cannot be fixed in-place — they must be deleted and reprovisioned.

---

## Rotating the passphrase requires deleting and reprovisioning every encrypted PVC

**Symptom.** After running `just rotate-luks-passphrase`, existing pods start failing with:

```
MountVolume.SetUp failed: rpc error: code = Internal desc = failed to publish volume:
unable to open LUKS device /dev/disk/by-id/scsi-0HC_Volume_...: No key available with this passphrase.
```

**Cause.** The LUKS header is baked into the Hetzner volume at format time. Updating the Kubernetes Secret only changes what passphrase future `luksOpen` calls will use. Existing volumes still have the old passphrase in their LUKS header.

**Fix.** After rotating the passphrase, run `just ops-recreate-encrypted-pvcs`. This deletes the old volumes (and their LUKS headers) and lets new ones be provisioned with the new passphrase. Data is lost for Grafana/Alertmanager/Tempo — acceptable because monitoring data is ephemeral. Prometheus is handled separately.

**If Prometheus data matters:** use `just ops-migrate-prometheus` before rotating, which copies data to a new encrypted volume first.

---

## WaitForFirstConsumer: temp PVC will never bind without a pod

**Symptom.** `just ops-migrate-prometheus` hangs at:

```
FAILED - RETRYING: Setup | Wait for temp PVC to be Bound (35 retries left).
```

**Cause.** `hcloud-volumes-encrypted` uses `volumeBindingMode: WaitForFirstConsumer`. The PVC stays `Pending` until a pod is actually scheduled that requests it. The playbook was waiting for Bound before creating the migration pod — a chicken-and-egg deadlock.

**Fix.** Already fixed in the playbook. The wait was removed. Instead, the migration pod is created immediately (which triggers provisioning), and the PVC is queried for its PV name *after* the pod completes.

**Recovery.** If you hit this on an old version of the playbook:
1. Ctrl+C the playbook
2. `kubectl delete pvc prometheus-migration-temp -n monitoring`
3. Pull latest, re-run

---

## ArgoCD selfHeal immediately reverts manual Application patches

**Symptom.** You patch the ArgoCD Application to remove `syncPolicy`, the command succeeds, but 2-3 seconds later the syncPolicy is back. Prometheus Operator gets restored to 1 replica seconds after you scale it to 0.

**Cause.** The root app-of-apps (`kubernetes/root-application.yaml`) has `selfHeal: true`. It watches all child Application objects. Any manual change to a child Application's spec is detected as drift from git and immediately reverted.

**Fix.** Stop the ArgoCD application controller *first*, before touching any Application objects:

```bash
kubectl scale statefulset argocd-application-controller -n argocd --replicas=0
# wait for it to stop
kubectl patch application kube-prometheus-stack -n argocd \
  --type=merge -p='{"spec":{"syncPolicy":null}}'
# ... do your work ...
kubectl scale statefulset argocd-application-controller -n argocd --replicas=1
```

With the controller stopped, no one can revert your changes. The playbooks now do this automatically.

**Verification.** Before pausing anything, check:
```bash
kubectl get application kube-prometheus-stack -n argocd \
  -o jsonpath='{.spec.syncPolicy}'
```
If it returns `{}` or non-null after you patched it to null, the controller is still running.

---

## Prometheus pod takes 10 minutes to terminate (terminationGracePeriodSeconds: 600)

**Symptom.** Playbook times out at:

```
FAILED - RETRYING: Pause | Wait for Prometheus pod to terminate (1 retries left).
fatal: [localhost]: FAILED!
```

The pod is still `Running` 3 minutes after scaling to 0.

**Cause.** Prometheus sets `terminationGracePeriodSeconds: 600` to allow the TSDB to flush all in-memory data to disk before shutdown. This is correct and intentional. The playbook's original wait (36 retries × 5s = 3 minutes) was shorter than the grace period.

**Fix.** Already fixed in the playbook (`retries: 120, delay: 10` = 20 minutes). Also `k8s_scale wait_timeout: 660`.

**If you're stuck mid-migration and the pod won't die:** it will terminate on its own within 10 minutes of the scale command. Wait it out. Check:
```bash
kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus -w
```

---

## kubernetes.core.k8s merge_type: json was removed in v4.0.0

**Symptom.**
```
value of merge_type must be one or more of: merge, strategic-merge. Got no match for: json
```

**Cause.** `merge_type: json` existed in older versions of the kubernetes.core Ansible collection to trigger RFC 6902 JSON Patch. It was removed in version 4.0.0. We have 6.4.0.

**Fix.** Use `kubernetes.core.k8s_json_patch` for RFC 6902 operations (add/remove/replace by path). Example — clearing a PV's claimRef:

```yaml
- name: Clear PV claimRef
  kubernetes.core.k8s_json_patch:
    kind: PersistentVolume
    name: "{{ pv_name }}"
    patch:
      - op: remove
        path: /spec/claimRef
```

Use `merge_type: merge` with `field: null` for removing a field via JSON Merge Patch (e.g., setting `syncPolicy: null`).

---

## ansible.builtin.command with -p={...} loses JSON key quotes

**Symptom.**
```
Error from server (BadRequest): error decoding patch: invalid literal 's' looking for beginning of object key string
```

The `cmd` in the task output shows `-p={spec:{syncPolicy:null}}` — the quotes around the keys are gone.

**Cause.** YAML parses `{"spec":{"syncPolicy":null}}` as a YAML flow mapping and re-serializes it without quotes. `ansible.builtin.command` with `cmd: >` gets the unquoted version.

**Fix.** Use `kubernetes.core.k8s` instead. It takes a Python dict and serializes it to valid JSON internally:

```yaml
- kubernetes.core.k8s:
    api_version: argoproj.io/v1alpha1
    kind: Application
    name: kube-prometheus-stack
    namespace: argocd
    merge_type: merge
    definition:
      spec:
        syncPolicy: null
```

Never use `ansible.builtin.command` with inline JSON in a YAML scalar. Use the k8s module or write the JSON to a temp file.

---

## kubernetes.core.k8s needs api_version for CRDs

**Symptom.**
```
Failed to find exact match for v1.Application by [kind, name, singularName, shortNames]
```

**Cause.** Without `api_version`, `kubernetes.core.k8s` searches the core API (`v1`). ArgoCD's `Application` is a CRD at `argoproj.io/v1alpha1`.

**Fix.** Always specify `api_version` for CRDs:

```yaml
- kubernetes.core.k8s:
    api_version: argoproj.io/v1alpha1
    kind: Application
    ...
```

Same applies to any other CRD (PrometheusRule, HTTPRoute, SealedSecret, etc.).

---

## Prometheus container is scratch-based — no df, no shell

**Symptom.**
```
OCI runtime exec failed: exec failed: unable to start container process:
exec: "df": executable file not found in $PATH
```

**Cause.** `quay.io/prometheus/prometheus` is built from scratch. It contains only the prometheus binary. No shell, no coreutils, no df.

**Fix.** Never use `kubernetes.core.k8s_exec` against the Prometheus container. To check disk usage before migration, query the PVC from the Kubernetes API instead:

```yaml
- kubernetes.core.k8s_info:
    kind: PersistentVolumeClaim
    name: "{{ old_pvc }}"
    namespace: monitoring
  register: pvc_info

- debug:
    msg: "Prometheus PVC: {{ pvc_info.resources[0].status.capacity.storage }}"
```

This gives you provisioned capacity. Actual usage is not available without exec, but capacity is enough to verify the temp PVC is large enough.

---

## PVC deletion race: ArgoCD re-creates PVC before old one is fully gone

**Symptom.** After deleting a PVC and re-enabling ArgoCD sync, the new pod starts but immediately gets:

```
MountVolume.SetUp failed: No key available with this passphrase.
```

The new PVC appears bound but is pointing at the old Hetzner volume with the old passphrase.

**Cause.** The old PVC was in `Terminating` (not yet fully deleted) when ArgoCD created the replacement PVC. The replacement bound to the old underlying PV, which still had the old LUKS header.

**Fix.** Always wait for the PVC to be fully gone — not just Terminating — before re-enabling ArgoCD. Use `kubernetes.core.k8s` with `state: absent, wait: true, wait_timeout: 180`. This blocks until the object disappears from the API completely. The playbook does this correctly.

**If you're in recovery:**
1. `kubectl get pvc <name> -n monitoring` — check if it shows `Terminating`
2. If stuck Terminating: `kubectl patch pvc <name> -n monitoring --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'`
3. Wait for it to disappear, then let ArgoCD create a fresh one

---

## Prometheus operator fights StatefulSet scale-to-0

**Symptom.** You scale `prometheus-kube-prometheus-stack-prometheus` StatefulSet to 0. Within seconds the pod comes back.

**Cause.** The Prometheus Operator watches the `Prometheus` custom resource and reconciles the StatefulSet to match it. The CRD says 1 replica, so the operator immediately restores the StatefulSet.

**Fix.** Scale the Prometheus Operator to 0 first:

```bash
kubectl scale deployment kube-prometheus-stack-operator -n monitoring --replicas=0
# wait for operator pod to terminate
kubectl scale statefulset prometheus-kube-prometheus-stack-prometheus -n monitoring --replicas=0
```

The playbook does both. If you are doing this manually, always do it in this order.

---

## PV retain-and-rebind: how to migrate data to a new encrypted PVC

This is the full procedure used when you need to preserve data (e.g., Prometheus TSDB). Used by `just ops-migrate-prometheus`.

**Concept.** Kubernetes won't let you rename a PVC. Instead: copy data to a temp encrypted PVC, set the temp PV to `Retain` (so deleting the PVC doesn't delete the data), delete the temp PVC, clear the PV's `claimRef`, then create a new PVC with the exact name the StatefulSet expects pre-bound to that PV.

**Steps at a glance:**

1. Create temp encrypted PVC (stays Pending until a pod mounts it — that's fine)
2. Launch rsync pod mounting both old PVC and temp PVC → temp PVC triggers provisioning
3. Rsync data
4. Get PV name: `kubectl get pvc prometheus-migration-temp -n monitoring -o jsonpath='{.spec.volumeName}'`
5. Set Retain: `kubectl patch pv <PV> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'`
6. Scale down Prometheus and Operator
7. Final delta rsync with `--delete` flag (catches anything written since step 3)
8. Delete temp PVC → PV transitions to Released (data intact because Retain)
9. Clear claimRef:
   ```bash
   kubectl patch pv <PV> --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'
   ```
   PV is now Available.
10. Delete old Prometheus PVC
11. Create new PVC with correct StatefulSet name pre-bound to retained PV:
    ```yaml
    spec:
      storageClassName: hcloud-volumes-encrypted
      volumeName: <PV name from step 4>
      accessModes: [ReadWriteOnce]
      resources:
        requests:
          storage: 10Gi
    ```
12. Restore operator, re-enable ArgoCD
13. After verifying data: restore PV reclaim policy to Delete

**Safety net.** Between steps 8 and 11, if something goes wrong the data is safe on the Released PV (Retain policy). You can always re-bind it by clearing the claimRef and creating a new PVC pointing at it.

---

## Orphaned Released PVs with Retain policy waste money

**Symptom.** After failed migration runs, `kubectl get pv` shows PVs in `Released` status with `Retain` reclaim policy. These are real Hetzner volumes costing ~€0.05/GiB/month.

**Cause.** Each failed migration run that got past the "Protect | Set PV to Retain" step left a PV behind when the temp PVC was deleted.

**Fix.** The migration playbook's cleanup section now automatically deletes Released encrypted PVs that aren't the current migration PV. After a successful run there should be none.

**Manual check:**
```bash
kubectl get pv -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,RECLAIM:.spec.persistentVolumeReclaimPolicy,SC:.spec.storageClassName' | grep Released
```

To delete: `kubectl delete pv <name>` — safe only if you're sure the data on it is not needed.

---

## Checking full encryption status

```bash
# All monitoring PVCs and their StorageClass
kubectl get pvc -n monitoring \
  -o custom-columns='NAME:.metadata.name,SC:.spec.storageClassName,STATUS:.status.phase'

# All encrypted PVs
kubectl get pv \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,CLAIM:.spec.claimRef.name,SC:.spec.storageClassName' \
  | grep hcloud-volumes-encrypted

# Verify LUKS is active on a node (SSH to the node where a pod is running)
lsblk -f | grep crypto_LUKS
```

Every PVC should show `hcloud-volumes-encrypted`. Any PVC showing `hcloud-volumes` (no `-encrypted`) is on an unencrypted volume.
