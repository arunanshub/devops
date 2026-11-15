# Kubelet Eviction Thresholds and PVC Deployment Strategy

Lessons from investigating high memory usage on cp-3 and fixing two gaps in cluster resilience.

---

## k3s has no memory eviction threshold by default

**Symptom.** `kubectl describe node` shows `MemoryPressure=False` even when a node is at 70%+ actual memory usage. No pods are evicted under memory pressure. `kubectl get --raw /api/v1/nodes/<node>/proxy/configz` shows:

```json
"evictionHard": {
    "imagefs.available": "5%",
    "nodefs.available": "5%"
},
"mergeDefaultEvictionSettings": false
```

No `memory.available` entry anywhere.

**Cause.** k3s sets `mergeDefaultEvictionSettings: false` in its generated kubelet config, which disables the kubelet's built-in default eviction thresholds (which would otherwise include `memory.available<100Mi`). The only active thresholds are the ones k3s explicitly sets itself — and it only sets disk thresholds, not memory.

Without a memory eviction threshold, the `MemoryPressure` node condition is never triggered, no pods are evicted under memory pressure, and the only backstop is the Linux kernel OOM killer — which kills processes unpredictably (could be etcd, k3s, or any pod).

**Fix.** Add memory eviction thresholds via `kubelet-arg+` in a k3s config drop-in:

```yaml
# /etc/rancher/k3s/config.yaml.d/eviction.yaml
kubelet-arg+:
  - "eviction-hard=memory.available<500Mi,imagefs.available<5%,nodefs.available<5%"
  - "eviction-soft=memory.available<1Gi"
  - "eviction-soft-grace-period=memory.available=2m0s"
```

The soft threshold gives pods a 2-minute grace period for graceful termination before the hard threshold triggers immediate eviction. This is managed by `ansible/playbooks/k3s-eviction.yml`.

---

## KubeletConfiguration drop-ins in `kubelet.conf.d` do not override k3s defaults

**Symptom.** A KubeletConfiguration file placed at `/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/eviction.yaml` is silently ignored — settings from it never appear in `/configz`.

**Cause.** k3s generates its own kubelet config at `/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/00-k3s-defaults.conf` on every restart. This file contains the authoritative kubelet configuration and wins over user-placed files in the same directory regardless of alphabetical ordering. The `kubelet.conf.d` drop-in approach advertised for k3s v1.32+ does not reliably allow overriding fields that k3s sets explicitly in `00-k3s-defaults.conf`.

**Fix.** Use `/etc/rancher/k3s/config.yaml.d/` with `kubelet-arg+` instead. This is k3s's own config merging mechanism and reliably appends to the kubelet flag list. When using `--eviction-hard`, include **all** eviction-hard signals in a single flag (not just the new ones) because the flag replaces the entire `evictionHard` map rather than merging per-key:

```yaml
# Correct — all signals together
kubelet-arg+:
  - "eviction-hard=memory.available<500Mi,imagefs.available<5%,nodefs.available<5%"

# Wrong — this replaces imagefs/nodefs thresholds with only memory
kubelet-arg+:
  - "eviction-hard=memory.available<500Mi"
```

---

## Deployments with ReadWriteOnce PVCs must use `Recreate` strategy

**Symptom.** After a pod reschedules to a different node (e.g. following a node restart), the new pod is stuck in `Init:0/1` indefinitely with:

```
Warning  FailedAttachVolume  Multi-Attach error for volume "pvc-..."
Volume is already used by pod(s) <old-pod-name>
```

The old pod never terminates because `RollingUpdate` waits for the new pod to be Ready first, and the new pod can never be Ready because it can't attach the volume. Permanent deadlock.

**Cause.** `RollingUpdate` strategy starts the new pod before terminating the old one. With a `ReadWriteOnce` PVC (Hetzner `hcloud-volumes`), only one node can hold the volume at a time. The old pod on the source node keeps the volume attached, blocking the new pod on the destination node.

**Fix.** Set `deploymentStrategy.type: Recreate` for any Deployment with a RWO PVC. `Recreate` terminates all existing pods first, releasing the volume, before starting the new pod.

```yaml
# kubernetes/base/monitoring/kube-prometheus-stack/values.yaml
grafana:
  deploymentStrategy:
    type: Recreate
```

**Pitfall.** Do not set `rollingUpdate: null` alongside `type: Recreate`. Helm's `toYaml` renders `null` values into the manifest as literal `null`, and Kubernetes rejects a Deployment spec that has `rollingUpdate: null` with `type: Recreate`. Just `type: Recreate` alone produces a clean manifest.

**Pitfall.** If ArgoCD shows `spec.strategy.rollingUpdate: Forbidden` after this change, the live Deployment object has a stale `rollingUpdate` block from when it was first created with `RollingUpdate`. Delete the Deployment manually — ArgoCD recreates it cleanly from the new values. The PVC and its data are unaffected.

---

## How to verify eviction thresholds on a live node

```bash
kubectl get --raw /api/v1/nodes/<node-name>/proxy/configz | python3 -c "
import json, sys
data = json.load(sys.stdin)
cfg = data['kubeletconfig']
print('evictionHard:', cfg.get('evictionHard'))
print('evictionSoft:', cfg.get('evictionSoft'))
print('evictionSoftGracePeriod:', cfg.get('evictionSoftGracePeriod'))
"
```

Expected output after the fix:

```
evictionHard: {'imagefs.available': '5%', 'memory.available': '500Mi', 'nodefs.available': '5%'}
evictionSoft: {'memory.available': '1Gi'}
evictionSoftGracePeriod: {'memory.available': '2m0s'}
```
