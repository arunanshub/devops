# CX33 Migration Notebook

> Record of the CPX32→CX33 rolling node migration completed 2026-06-08.
> Kept as a runbook for the next time a node type changes (the `tofu -replace`
> requirement, etcd member removal, drop-in restore, and the enp7s0 race are
> all reusable). See also `docs/talos-migration-attempt.md`.

## What you're running today

```
3x CPX32 in hel1
  cpu:  4 vCPU  AMD EPYC Genoa (Zen 4) — guaranteed
  ram:  8 GB
  disk: 160 GB SSD
  cost: €10.99/mo × 3 = €32.97/mo
  traffic: 20 TB/mo included
```

## What CX33 is

```
4 vCPU / 8 GB RAM / 80 GB SSD
cost: €5.49/mo × 3 = €16.47/mo
traffic: 20 TB/mo included
savings: €16.50/mo (~50%)
```

CPU architecture: **Intel OR AMD, randomly assigned, cannot control**.
- Intel allocation → Intel Xeon Skylake (2015–2017 era). ~3x slower single/multi-core vs EPYC Genoa.
- AMD allocation → AMD EPYC Rome (~2.45 GHz). Acceptable.
Source: https://docs.hetzner.com/cloud/servers/faq/
Source: https://proneta.lt/hetzner-cloud-showdown-intel-xeon-vs-amd-epyc-hetzner-cloud-cx33-vs-cpx32/

## Hard blocker: direct rescale is impossible

Hetzner blocks disk downgrade. CPX32 = 160 GB, CX33 = 80 GB.
FAQ: "Rescaling to a plan with a smaller disk is not possible, regardless of how much storage you are actually using."
Snapshot-to-smaller-disk is also blocked (Hetzner copies full disk allocation).

Actual disk usage on cp-1: 14 GB out of 150 GB (10%). Fits in 80 GB with plenty of headroom.

## How auto-join works (locals.tf:34)

```hcl
"cluster-init" = (k == var.bootstrap_node && !var.is_cluster_initialized) ? true : null
"server"       = (k == var.bootstrap_node && !var.is_cluster_initialized) ? null : "https://10.0.0.100:6443"
```

Since `is_cluster_initialized = true` is already set, ALL nodes (including any new ones, including
a new cp-1) get `server: https://10.0.0.100:6443` in config.yaml. cloud-init drops the config
and runs `curl | sh -`. k3s starts, node joins. No manual intervention needed.

## How etcd member removal works in k3s

k3s-uninstall.sh does NOT remove etcd members (confirmed: k3s issue #4865).
k3s DOES handle etcd removal via a finalizer on the node object.

Correct procedure:
1. kubectl annotate node <node> k3s.io/force-remove=true   ← signals etcd removal immediately
2. kubectl delete node <node>                               ← finalizer blocks until etcd member gone
   (k3s controller on remaining nodes processes the removal)
3. Wait ~60s for etcd leader election to stabilize before touching next node
4. Then destroy the Hetzner server (it's already gone from the cluster)

Source: k3s issue #13498. Recent k3s releases (cluster is on v1.35.5+k3s1) also do explicit
leader transfer before member removal.

## PVC / storage (no action needed for rolling replacement)

All 3 PVCs use Hetzner CSI (network-attached volumes). They stay attached, move with pods.
When a node is drained, pods reschedule, CSI detaches from old node, reattaches on new node.
No data loss. No orphaned volumes.

## Migration plan: rolling node replacement, zero downtime

Do cp-3 → cp-2 → cp-1 (bootstrap node last).
Each iteration takes ~15–20 minutes. Cluster stays live throughout.

### Per-iteration procedure

#### Step 1: Drain the old node
```bash
kubectl drain hetzner-k3s-cp-3 --ignore-daemonsets --delete-emptydir-data
```
Pods migrate to remaining nodes. CSI volumes detach and reattach.

#### Step 2: Stop k3s on the old node
```bash
ssh root@<cp-3-ipv6> 'systemctl stop k3s'
```
Prevents the old server from trying to rejoin after etcd removal.

#### Step 3: Remove from etcd + cluster
```bash
kubectl annotate node hetzner-k3s-cp-3 k3s.io/force-remove=true
kubectl delete node hetzner-k3s-cp-3
# wait for the delete to complete (finalizer is released when etcd member is gone)
kubectl wait --for=delete node/hetzner-k3s-cp-3 --timeout=120s
sleep 60   # let etcd leader election settle
```

#### Step 4: Update tfvars and apply
In terraform.tfvars, change just the one node's server_type:
```hcl
"cp-3" = { server_type = "cx33", role = "cp_worker", location = "hel1", private_ip = "10.0.0.4" }
```
```bash
tofu apply
```
tofu destroys old Hetzner server, creates new CX33 at same name + private IP.
New server boots → cloud-init writes k3s config (server: https://10.0.0.100:6443) → k3s starts → joins cluster.

#### Step 5: Verify before moving on
```bash
kubectl get nodes   # wait for new cp-3 to show Ready
# check etcd health:
ssh root@<any-remaining-cp-ipv6> 'k3s etcd-snapshot ls'   # or: k3s kubectl get nodes
```

### cp-1 special handling

cp-1 is the bootstrap_node. After tofu replaces it, terraform_data.kubeconfig
triggers_replace (watches cp-1's server ID) and automatically re-fetches infra/kubeconfig.yaml
from the new node's IPv6. No manual kubeconfig update needed.

### The 2-node window

Between step 3 (etcd member removed) and step 4 (new node joins, ~1–2 min):
- Cluster runs on 2 nodes, etcd quorum is 2/2 (zero fault tolerance during this window)
- Cluster is fully functional (API server works, workloads run)
- Keep this window short; don't run apply on next node until new one is Ready

If you want to eliminate this window entirely: add a temporary cp-4 (CX33, 10.0.0.5) first,
confirm it's Ready, then start the rolling drain. Keeps 3-node etcd throughout.
Remove cp-4 after all 3 original nodes are replaced.

## Post-migration

1. `just verify-mtu` — WireGuard + VXLAN stack must be re-validated on new hardware
2. Check `lscpu` on each new node — CX33 may get Intel Skylake (3x slower than current Genoa).
   If Skylake: `tofu taint 'hcloud_server.nodes["cp-X"]'` + `tofu apply` to reprovisio and hope
   for AMD allocation. This is luck-based but worth one retry.

## EXECUTION CORRECTIONS (learned during cp-3, apply to cp-2 + cp-1)

### 1. server_type change = in-place RESCALE, not destroy+create
Plain `tofu apply` after changing server_type shows `~ update in-place` and would
call Hetzner's rescale API → FAILS on disk shrink (160→80). MUST force replacement:
```bash
sops exec-env secrets.yaml 'tofu apply -replace='\''hcloud_server.nodes["cp-X"]'\'' -auto-approve'
```
Verify the plan shows: cp-X server replaced + its LB target replaced + 2 firewall
attachments updated in-place; cp-1/cp-2 servers untouched; terraform_data.kubeconfig
NOT triggered (only fires on cp-1 replacement).

### 2. New node reuses the SAME public IPv4/IPv6 (Hetzner kept them for cp-3)
But it's a fresh OS = new SSH host key. Clear stale keys before SSH/ansible:
```bash
ssh-keygen -R '<ipv6>'                                  # personal ~/.ssh/known_hosts
ssh-keygen -R '<ipv6>' -f infra/.ssh_known_hosts        # ansible's known_hosts (accept-new won't fix a CHANGED key)
```

### 3. config.yaml.d drop-ins are NOT restored by cloud-init — re-run ansible per node
Fresh node has only cloud-init's config.yaml. Missing: eviction.yaml, resolv-conf.yaml,
etcd-snapshots.yaml. Restore (each restarts that node's k3s once, idempotent elsewhere):
```bash
just _ansible-playbook baseline           "--limit hetzner-k3s-cp-X"
just _ansible-playbook k3s-eviction        "--limit hetzner-k3s-cp-X"
just _ansible-playbook k3s-resolver        "--limit hetzner-k3s-cp-X"
just _ansible-playbook k3s-etcd-snapshots  "--limit hetzner-k3s-cp-X"
```
k3s-coredns-ha is cluster-level (localhost), not per-node — skip, just confirm CoreDNS 2/2.

### 4. etcd member-removal verification (no etcdctl bundled)
Authoritative proof of clean removal = k3s log on a surviving node:
```bash
ssh root@<cp-1-ipv6> 'journalctl -u k3s --since "15 min ago" | grep -iE "ConfChangeRemoveNode|removed member"'
```
`active_peers=0` in etcd metrics is a STALE series, not a ghost — trust the raft log.

### 5. PRE-EXISTING cluster-wide MTU regression (NOT caused by migration)
`just verify-mtu` FAILS: cross-node pods drop packets ≥~1280B payload on ALL pairs,
including untouched cp-1↔cp-2. cilium_wg0=1355 (expected 1370) on all 3 nodes.
Untouched nodes' cilium agents are 17h old → predates this migration. TCP survives
(MSS clamping, likely) so apps are healthy. The verify-mtu script also has a pipefail
bug that mangles the loss% readout, but the loss is REAL (reproduced manually).
DEFER fix — it's a Cilium WG-overhead/MTU config change w/ cluster-wide agent restarts;
do it as its own task AFTER all 3 nodes are CX33. Do not interleave with migration.

### cp-3 outcome: AMD CPU (won lottery), 80GB disk (3.4G used), identical to peers.

### 6. HETZNER PRIVATE-NIC RACE (hit cp-2, watch for it on cp-1!)
New node booted with enp7s0 DOWN — cloud-init rendered netplan (50-cloud-init.yaml) with
ONLY eth0, missing the enp7s0 stanza, because the Hetzner private network wasn't attached
yet when cloud-init ran. Result: no 10.0.0.x IP, no private route, k3s crash-loops on
"failed to get CA certs https://10.0.0.100:6443" (LB unreachable). cloud-init shows
scripts_user error (downstream effect). cp-3 dodged this race; cp-2 hit it.
FIX (deterministic, in-place, persistent) — get enp7s0 MAC from `ip link show enp7s0`:
```bash
ssh root@<new-node-ipv6> 'cat > /etc/netplan/99-private-network.yaml <<EOF
network:
  version: 2
  ethernets:
    enp7s0:
      match:
        macaddress: "<ENP7S0_MAC>"
      dhcp4: true
      set-name: "enp7s0"
EOF
chmod 600 /etc/netplan/99-private-network.yaml && netplan apply'
```
enp7s0 gets 10.0.0.x via DHCP + route 10.0.0.0/16 via 10.0.0.1; crash-looping k3s joins
within ~40s. tls-san marker IS still replaced correctly (sed uses eth0 which is up).
cp-2 outcome: AMD, 80GB, joined after netplan fix, identical to peers (carries the 99-private file as a snowflake — clean up later or harden init.sh.tpl to bring up enp7s0).

## Summary

| | Before | After |
|---|---|---|
| Server type | CPX32 (AMD EPYC Genoa) | CX33 (Intel or AMD — luck) |
| Monthly cost | €32.97 | €16.47 |
| Downtime | — | Zero (rolling) |
| Data loss | — | None |
| Difficulty | — | Low |
| Risk | — | Architecture lottery on CPU |
