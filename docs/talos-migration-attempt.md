# Talos Migration Attempt — What Happened and What We Learned

We tried to migrate from k3s to Talos Linux on 2026-05-31. It took ~8 hours, the cluster was down the whole time, and we ended up reverting. Read this before attempting again.

---

## Why we wanted Talos

- No SSH daemon on the nodes → smaller attack surface
- Declarative OS config via machineconfig instead of ansible playbooks
- Drop kured and system-upgrade-controller for OS updates
- Immutable OS, cleaner separation of concerns

All of these are still valid reasons. The problems below are fixable. We just didn't have the right information going in.

---

## What runs now instead

Three cpx32 nodes in hel1 (cx33 is currently unavailable in that region — same specs, ~€4/month more). k3s v1.35.5. All data volumes reattached with original data intact. Grafana data was lost (see the PV recovery section below).

---

## The five things that killed the migration

### 1. Using the wrong factory image type

**What we did:** downloaded `metal-amd64.raw.zst` from factory.talos.dev and wrote it to disk.

**What happened:** the node booted with `platform: metal`. Hetzner's private network uses a routed /32 setup — each server has a route `10.0.0.0/16 via 10.0.0.1` with the IP assigned as /32 via DHCP. The `metal` platform doesn't configure any of this. The node gets no network beyond the public interface. k3s-style API endpoints at 10.0.0.100 are unreachable. Port 50000 appears open but nothing that depends on the private network works.

**The actual correct image type:** `hcloud-amd64.raw.xz`. This is not just a format difference. The `hcloud` image type has `platform: hcloud` baked in, which tells Talos to fetch network config from Hetzner's metadata service (169.254.169.254). The private interface gets DHCP, the correct routes appear, everything works.

```
# WRONG — always produces platform: metal, private network broken
https://factory.talos.dev/image/<schematic>/v1.12.4/metal-amd64.raw.zst

# CORRECT — hcloud platform, private network works
https://factory.talos.dev/image/<schematic>/v1.12.4/hcloud-amd64.raw.xz
```

`xz -d` is pre-installed on Ubuntu/Debian. No extra packages needed.

---

### 2. The `siderolabs/hcloud` extension doesn't exist

**What we did:** created a custom factory schematic that referenced `siderolabs/hcloud` as a system extension, expecting it to handle platform detection.

**What happened:** the factory returned 400 for every image request — "official extension siderolabs/hcloud is not available for Talos version vX.Y.Z". Every version. The extension simply does not exist.

**The correct schematic:** only use extensions that actually exist. `siderolabs/qemu-guest-agent` works for Hetzner VMs. If you want `talos.platform=hcloud` baked into the UKI cmdline (needed for `metal-installer` to produce the right platform after self-install), add it via `extraKernelArgs`:

```yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/qemu-guest-agent
  extraKernelArgs:
    - talos.platform=hcloud
```

POST this to `https://factory.talos.dev/schematics`, get back the schematic ID, verify it returns 200:

```bash
curl -sIL "https://factory.talos.dev/image/<schematic-id>/v1.12.4/hcloud-amd64.raw.xz" | head -3
# Should show: HTTP/2 200
```

---

### 3. Setting user_data to a shell script

**What we did:** put a bash install script in the Hetzner server's `user_data` field (via Terraform). The script downloaded the Talos image, dd'd it to disk, and rebooted.

**What happened:** cloud-init ran the script fine and installed Talos correctly. But after reboot, Talos (`platform: hcloud`) reads the Hetzner metadata service for its machineconfig at boot. It found the bash script in user_data. It tried to parse it as YAML. It failed. It retried every 20 seconds. Port 50000 never opened.

The log loop looks like this:
```
[talos] fetching machine config from "http://169.254.169.254/hetzner/v1/userdata"
controller failed: failed to load config via platform hcloud: expected a YAML document at line 7
```

**The rule:** Hetzner `user_data` must be either:
- **Empty** — Talos enters maintenance mode, port 50000 opens, you apply config with `talosctl apply-config --insecure`
- **A valid Talos machineconfig YAML** — Talos reads it, configures itself, reboots into running state

A shell script, a cloud-config, anything else — Talos will loop-fail and never open port 50000.

---

### 4. Booting from disk instead of the Hetzner public ISO

**What we tried first:** attach the Hetzner public Talos ISO via Terraform `iso = "hcloud-v1-12-4.amd64.iso"` and create the server with `image = "debian-12"`.

**What happened:** Hetzner creates the server with debian-12 on disk. The ISO is attached but the BIOS boots from disk first because debian has a valid bootloader. The server runs debian, port 22 is not open (our firewall blocks it), port 50000 is connection-refused (nothing listens). The ISO UI shows in the Hetzner console as "mounted" but it's not the boot device.

**The correct approach:** create the server with no user_data, then:

```bash
hcloud server attach-iso hetzner-talos-cp-1 hcloud-v1-12-4.amd64.iso
hcloud server reboot hetzner-talos-cp-1
```

After reboot, the server boots from ISO (it forces the ISO as the boot device). Talos enters maintenance mode. Port 50000 opens. Apply config. Detach ISO immediately after:

```bash
hcloud server detach-iso hetzner-talos-cp-1
```

Detach before the node reboots post-install. If the ISO is still attached when the node reboots after `talosctl apply-config`, it will boot from the ISO again (back to maintenance mode, loop restarts).

The Justfile has `just talos-iso-boot` and the apply recipe handles the detach automatically.

---

### 5. TALOSCONFIG not set outside just recipes

**What we did:** added `export TALOSCONFIG := talos_configs / "talosconfig"` to the Justfile. Every `talosctl` call inside a `just` recipe used the right config.

**What happened:** when we ran `talosctl` directly from the shell (for debugging), it used `~/.talos/config` instead, which pointed at a local docker cluster. Error: `dial tcp 127.0.0.1:45089: connect: connection refused`. Completely misleading.

**The fix:** always either:
- Run talosctl through just recipes (they export the var)
- Or set it explicitly: `TALOSCONFIG=talos/clusterconfig/talosconfig talosctl ...`

---

## The correct bootstrap sequence (if you retry)

This is the sequence that works, in order. Don't skip steps.

```
1. just apply
   # Creates 3 nodes with NO user_data. They boot debian-12 idle.

2. just node-ipv6s
   # Reads current IPv6 addresses from tofu output.

3. just talos-iso-boot
   # Attaches hcloud-v1-12-4.amd64.iso to all 3 nodes and reboots them.
   # Nodes boot ISO → Talos maintenance mode → port 50000 opens.

4. just talos-apply-configs <cp1-ipv6> <cp2-ipv6> <cp3-ipv6>
   # Waits for port 50000 on all 3 nodes.
   # Generates machineconfigs (talhelper), patches installer to custom schematic.
   # Applies to each node. Node installs Talos to disk, then reboots.
   # Detaches ISOs immediately so reboot lands on disk, not ISO.

5. just talos-bootstrap <cp1-ipv6>
   # Waits for node to come back (port 50000 with mTLS this time).
   # Bootstraps etcd. Cluster forms.

6. just talos-upgrade v1.13.2
   # Optional. Upgrade from the ISO version to latest.

7. just talos-kubeconfig <cp1-ipv6>
   # Fetches kubeconfig. Writes to infra/kubeconfig.yaml.

8. just argocd-bootstrap
   # Installs Cilium, hccm, ArgoCD via helmfile.
   # Nodes flip to Ready.

9. just argocd-ssh-bootstrap
10. just restore-sealed-secrets-key
11. just talos-cutover-post   # pre-creates PVs/PVCs for existing data volumes
12. just argocd-root-bootstrap
```

Step 11 is critical — see the PV recovery section below.

---

## PV recovery after cluster rebuild

The Hetzner block volumes survive a cluster rebuild if you set reclaim policy to Retain before teardown. The volumes have no cluster — they just exist in Hetzner, unattached.

**How to get them back:** pre-create static PV objects with the volume IDs before ArgoCD syncs. If ArgoCD syncs first, the Helm charts create new PVCs which get new (empty) volumes.

```yaml
# Example PV manifest
apiVersion: v1
kind: PersistentVolume
metadata:
  name: talos-prometheus
spec:
  storageClassName: hcloud-volumes-encrypted
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  csi:
    driver: csi.hetzner.cloud
    fsType: ext4
    volumeHandle: "105813992"   # the actual Hetzner volume ID
    nodePublishSecretRef:
      name: hcloud-luks-key
      namespace: kube-system
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: csi.hetzner.cloud/location
              operator: In
              values: [hel1]
```

Pre-created PVCs reference the PV by name with `spec.volumeName`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
  namespace: monitoring
spec:
  storageClassName: hcloud-volumes-encrypted
  volumeName: talos-prometheus    # ← binds to the named PV
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
```

**StatefulSet PVCs (Prometheus, Alertmanager, Tempo):** bind correctly because the StatefulSet adopts existing PVCs by name. Data comes back intact.

**Standalone Helm PVCs (Grafana):** conflict with ArgoCD. ArgoCD wants to own the PVC, but the spec is immutable once bound. You have two options:
- Delete the pre-created PVC and let Helm create a new one (fresh volume, data lost, but Grafana data is usually reconstructible)
- Keep it and add `ignoreDifferences` + `RespectIgnoreDifferences=true` to the ArgoCD application — but this didn't work reliably with ServerSideApply in testing, so deleting is simpler

**Volume IDs for this cluster's data volumes** (as of 2026-05-31):

| Hetzner Volume ID | Workload | PVC Name |
|---|---|---|
| 105813109 | Grafana | `kube-prometheus-stack-grafana` |
| 105813992 | Prometheus | `prometheus-kube-prometheus-stack-prometheus-db-...-0` |
| 105813103 | Alertmanager | `alertmanager-kube-prometheus-stack-alertmanager-db-...-0` |
| 105813104 | Tempo | `storage-tempo-0` |

Check current volumes with `hcloud volume list`. If a volume was deleted (Grafana's was deleted on 2026-06-01), skip it.

---

## What changed in the revert

The migration was committed to git and then reverted back to k3s. Permanent differences from the pre-migration baseline:

| Thing | Before | After |
|---|---|---|
| Server type | cx33 | cpx32 (cx33 unavailable in hel1) |
| `is_cluster_initialized` | true | false (fresh cluster needed reset) |
| k3s token | old | new (regenerated on revert) |
| system-upgrade drain | `timeout: 300` | drain block removed (bare integer = nanoseconds, broke drain) |
| Grafana data | present | lost (volume deleted) |
| Everything else | unchanged | unchanged |

---

## Talos-specific things in the repo

The `talos/` directory still exists with:
- `talconfig.yaml` — cluster definition for talhelper
- `talsecret.sops.yaml` — encrypted cluster CA and bootstrap tokens (don't lose these if you want to retry)
- `patches/` — eviction thresholds, controlplane SANs, cluster settings

These are dormant. They don't affect the running k3s cluster. If you retry the migration, this is your starting point.

The Justfile still has all `talos-*` recipes. Run `just --list` to see them.

---

## If you're troubleshooting port 50000

Possible states and what each one means:

| What `nc -6 -v <ip> 50000` shows | What it means |
|---|---|
| `Connected` | Talos maintenance mode, ready for `apply-config --insecure` |
| `Connection refused` | OS is running but nothing on 50000. Either debian-12 booted (not the ISO), or Talos is stuck retrying invalid user_data |
| `TIMEOUT` | Hetzner firewall is dropping the packet. Your home IPv6 doesn't match `TF_VAR_home_ip`. Run `curl https://api6.ipify.org`, compare to the firewall rule, update secrets.yaml + `just apply` |

When it's "connection refused" and you expect Talos: check `user_data` first. If it contains anything other than a machineconfig YAML or nothing, that's why.
