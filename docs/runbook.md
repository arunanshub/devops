# Operator Runbook

This repo provisions and operates a self-managed k3s cluster on Hetzner Cloud.

```text
OpenTofu   -> Hetzner infrastructure
cloud-init -> first boot only
Ansible    -> host OS convergence
ArgoCD     -> Kubernetes workloads
```

Work from `devbox shell` so the pinned tool versions in `devbox.json` are used.

## Daily Commands

```bash
just --list
just plan
just ansible-check
just ansible-converge
```

`just` exports `KUBECONFIG=infra/kubeconfig.yaml`, so Kubernetes commands can be
run from the repo after infrastructure bootstrap.

## Repository Map

- `infra/` - OpenTofu for Hetzner servers, firewall, network, SSH key, API load balancer, kubeconfig generation.
- `infra/scripts/init.sh.tpl` - cloud-init first-boot script. Keep this minimal.
- `ansible/` - host configuration convergence over SSH.
- `kubernetes/bootstrap/` - one-time Helmfile bootstrap path.
- `kubernetes/infra/` - ArgoCD-managed infrastructure applications.
- `kubernetes/monitoring/` - ArgoCD-managed monitoring applications.
- `docs/bootstrap-pitfalls.md` - bootstrap failure notes.
- `docs/specs/` - architectural decisions.

## Infrastructure

Plan first:

```bash
just plan
```

Apply only after reading the plan:

```bash
just apply
```

Destroy is explicit:

```bash
just destroy
```

Topology is declared in `infra/terraform.tfvars` through `nodes`. Each node has:

- `server_type`
- `role`: `cp_only`, `cp_worker`, or `worker`
- `location`
- `private_ip`

The OpenTofu checks enforce:

- odd control-plane count
- valid bootstrap node role
- unique node private IPs
- node and API-LB private IPs inside the Hetzner subnet

### Modifying Nodes

For small topology edits:

1. Edit `infra/terraform.tfvars`.
2. Run `just plan`.
3. Read replacement/addition/removal effects carefully.
4. Apply only if the plan preserves quorum and availability.
5. Run `just ansible-check`.
6. Run `just ansible-converge`.

Do not casually replace multiple control-plane nodes at once. Embedded etcd
requires quorum. In a three-control-plane cluster, one unavailable control-plane
node is acceptable; two is not.

### Where Changes Belong

- Hetzner resources: `infra/`.
- First boot identity/bootstrap only: `infra/scripts/init.sh.tpl`.
- Running host state: `ansible/`.
- Kubernetes workloads: `kubernetes/` through ArgoCD.

If the change is "make existing machines converge to this state", prefer
Ansible over `user_data`.

## Ansible

Ansible is the normal path for host-state changes. Manual SSH that changes host
state is break-glass only.

```text
Manual SSH for diagnosis: okay when needed.
Manual SSH for mutation: avoid.
Ansible over SSH for convergence: normal.
```

### Inventory

Inventory is generated dynamically from OpenTofu outputs:

```bash
just ansible-inventory
```

The Go inventory tool reads:

- `tofu output -json`
- `ANSIBLE_TOFU_OUTPUTS`, when set, for tests/offline runs
- `ANSIBLE_SSH_PRIVATE_KEY_FILE`, when overriding the key
- `ANSIBLE_KNOWN_HOSTS_FILE`, when overriding known-hosts storage

Hosts are grouped as:

- `k3s_nodes`
- `control_planes`
- `workers`

### Check Before Apply

Always check first:

```bash
just ansible-check
```

Then converge:

```bash
just ansible-converge
```

Both default to `ansible/playbooks/site.yml`. To run one playbook:

```bash
just ansible-check baseline
just ansible-converge baseline
```

Compatibility aliases also exist:

```bash
just ansible-baseline-check
just ansible-baseline
```

### Adding Host Configuration

Add roles under `ansible/roles/`.

Add playbooks under `ansible/playbooks/`.

Wire ordering in `ansible/playbooks/site.yml`, not in `Justfile`.

Use this rule of thumb:

- Safe fleet-wide config: can run in parallel.
- Restarting or disruptive config: use explicit serial/gated playbooks.
- k3s control-plane changes: one control-plane node at a time, with health checks.

The current baseline role manages unattended upgrades only.

## Node Lifecycle

Adding and replacing nodes is declarative — edit the tofu topology, apply,
then converge host config with the existing one-shot playbooks. No wrapper
tooling; the value below is the ORDER and the gates.

### Add a node

1. Add the node to `var.nodes` (key like `worker-2`; key becomes the k8s Node
   name suffix).
2. `just plan`, review, `just apply`. Cloud-init installs k3s on first boot.
3. Wait for the node to join:
   `kubectl wait node/hetzner-k3s-<key> --for=condition=Ready --timeout=15m`
4. Converge host config. The k3s playbooks are deliberate one-shots (each may
   restart k3s, serial:1) — run them explicitly, in this order; unchanged
   nodes no-op:

   ```bash
   just ansible-converge                          # baseline (site.yml)
   just ansible-converge k3s-eviction             # all nodes
   just ansible-converge k3s-resolver             # all nodes
   just ansible-converge k3s-embedded-registry    # control planes only
   just ansible-converge k3s-etcd-metrics         # control planes only
   just ansible-converge k3s-etcd-snapshots       # control planes only
   ```

5. `just opsctl cluster verify`

Do NOT generate/refresh the ansible inventory mid `tofu apply` (a node with
no IPv6 yet is emitted with an empty `ansible_host`).

### Replace a node

Same as add, with the guard dance around the destroy (the guards are
intentional — do not script around them):

1. Preflight: every node Ready (`kubectl get nodes`), and note that replacing
   the node your kubeconfig points at (cp-1 public IPv6 under Option B admin
   access) cuts your own API access mid-operation.
2. Relax the guards for the target node in `infra/servers.tf`
   (`lifecycle.prevent_destroy`, `delete_protection`, `rebuild_protection`)
   and `just apply` that change first.
3. `sops exec-env infra/secrets.yaml 'tofu apply -replace=hcloud_server.nodes["<key>"]'`
   from `infra/` (use `-replace`, never a hand-edited plan).
4. Continue from step 3 of "Add a node" (wait Ready → converge → verify).
5. Revert the guard relaxation and `just apply` again.

## Fresh Cluster Bootstrap

The sequence is encoded (with ordering guards) in:

```bash
just opsctl cluster bootstrap --list-steps   # see the steps
just opsctl cluster bootstrap --dry-run      # print every command
just opsctl cluster bootstrap                # run it
just opsctl cluster bootstrap --from-step X  # resume after a failure
```

It refuses to run the helmfile steps when the ArgoCD root Application already
exists — after that point ArgoCD owns the cluster and re-running helmfile
fights it for ownership.

The equivalent manual recipes, in order:

```bash
just apply
just argocd-bootstrap
just argocd-ssh-bootstrap
just restore-sealed-secrets-key
just argocd-root-bootstrap
```

Important:

- `argocd-bootstrap` is a one-time Helmfile bootstrap path.
- After `argocd-root-bootstrap`, ArgoCD owns the cluster.
- Do not re-run `just argocd-bootstrap` after ArgoCD has taken ownership.

Then verify:

```bash
kubectl get nodes
kubectl get pods -A
kubectl get applications -n argocd
just ansible-check
```

If SealedSecrets fail to decrypt, confirm `restore-sealed-secrets-key` ran before
`argocd-root-bootstrap`.

## Kubernetes Operations

ArgoCD is the steady-state deployer. Prefer Git changes over `kubectl apply`.

Root application:

```bash
just argocd-root-bootstrap
```

Useful local UIs:

```bash
just launch-argocd-ui
just launch-grafana
just launch-hubble-ui
```

### Adding an ArgoCD Application

1. Create `kubernetes/infra/<app>/application.yaml`.
2. Add values at `kubernetes/infra/<app>/values.yaml`.
3. Add the application path to `kubernetes/infra/kustomization.yaml`.
4. Add chart repos/namespaces to the AppProject if needed.
5. Commit and let ArgoCD reconcile.

For monitoring apps, use the same pattern under `kubernetes/monitoring/`.

### Secrets

SOPS files should be named `*.sops.yaml` or `*.secrets.yaml`.

Before encrypting Kubernetes Secret YAML, strip runtime metadata:

- `creationTimestamp`
- `resourceVersion`
- `uid`
- `ownerReferences`

Bootstrap secrets are applied through `just` recipes. Steady-state secrets should
be represented as SealedSecrets and reconciled by ArgoCD.

## Validation

Before committing:

```bash
go test ./...
just --fmt --check
git diff --check
```

OpenTofu validation and YAML formatting are also wired through lefthook.

For infrastructure-sensitive work, run:

```bash
just plan
```

For host-state-sensitive work, run:

```bash
just ansible-check
```

## Debugging: Node Stuck Unschedulable / Pod Pending

Symptom: a pod is `Pending`, a node shows `SchedulingDisabled`. Often surfaces at
night after kured runs its maintenance window reboot.

### Step 1 — find what is broken

```bash
kubectl get pods -A | grep -v Running | grep -v Completed
kubectl describe pod <pending-pod> -n <ns>
```

Read the `Events` section. The scheduler spells out the reason:

```text
0/3 nodes are available: 1 node(s) were unschedulable,
2 node(s) didn't have free ports for the requested pod ports.
```

"Unschedulable" = a node is cordoned. "Free ports" = another node already has a
`hostPort`-using pod on that port (e.g. hccm's metrics port 8233 with
`hostNetwork: true`).

### Step 2 — identify the cordoned node and who owns the cordon

```bash
kubectl get nodes
# look for SchedulingDisabled in the STATUS column
```

Two things cordon nodes in this cluster: kured (node reboot) and
system-upgrade-controller (k3s upgrade). Check kured first when the time is
inside the 02:00–04:00 IST maintenance window.

```bash
# Is kured holding a lock on this node?
kubectl get ds kured -n kube-system \
  -o jsonpath='{.metadata.annotations.weave\.works/kured-node-lock}'
```

If `nodeID` matches the cordoned node, kured is responsible. The `unschedulable`
field records the node's state *before* kured cordoned it — `false` means the
node was healthy and kured cordoned it for a routine reboot.

If kured is not the owner, check system-upgrade-controller:

```bash
kubectl logs -n system-upgrade \
  -l app=system-upgrade-controller --tail=50 | grep -i 'cordon\|uncordon\|error'
```

A recurring `jobs.batch "<job>" not found, requeuing` error means the SUC
controller restarted mid-upgrade, lost its reference to the completed job, and
never ran the uncordon step. Since all nodes will already be at the target k3s
version in this case, it is safe to uncordon manually (see Step 4).

### Step 3 — if kured is stuck, find what is blocking the drain

```bash
kubectl logs -n kube-system <kured-pod-on-cordoned-node> --tail=30
```

If you see:

```text
Cannot evict pod as it would violate the pod's disruption budget.
```

repeating every 5 seconds, a PDB is blocking the drain. Find which one:

```bash
kubectl get pdb -A
```

Look for `ALLOWED DISRUPTIONS: 0`. This means the PDB's `minAvailable` equals
the current running pod count — eviction would breach the minimum, so Kubernetes
blocks it indefinitely. The drain never completes, the node stays cordoned.

**Root cause:** `minAvailable: 1` on a single-replica workload. When there is
only one pod, evicting it would drop the count to zero, which always violates
`minAvailable: 1`. The correct setting for single-replica workloads is
`maxUnavailable: 1` — this permits eviction while accepting a brief reschedule
window (typically 30–60 s). See `docs/bootstrap-pitfalls.md` for context on
why `minAvailable` vs `maxUnavailable` matters.

Also check: when overriding a Helm chart's PDB values, always explicitly set
`minAvailable: null` when adding `maxUnavailable`, otherwise Helm merges both
from the chart defaults and Kubernetes rejects the object.

### Step 4 — fix and recover

**PDB blocking drain (kured stuck):**

Fix the PDB in the relevant values or manifest file, push, and wait for ArgoCD
to apply. Once `ALLOWED DISRUPTIONS` becomes 1, kured's next retry will succeed,
the reboot will proceed, and kured will uncordon the node automatically after
the node comes back.

Do not manually release the kured lock or uncordon while kured is mid-drain —
let kured finish its cycle so the reboot actually happens.

**SUC stuck cordon (controller restarted mid-upgrade):**

Confirm all nodes are already at the target k3s version:

```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,UNSCHEDULABLE:.spec.unschedulable'
```

If the stuck node matches the others, the upgrade is complete. Uncordon manually:

```bash
kubectl uncordon <node>
```

### Step 5 — verify recovery

```bash
kubectl get nodes
kubectl get pods -A | grep -v Running | grep -v Completed
kubectl get pdb -A
```

All nodes should be `Ready` (no `SchedulingDisabled`), all pods running, and
`ALLOWED DISRUPTIONS` ≥ 1 on every PDB.

## Hard Rules

- Read `just plan` before applying.
- Preserve control-plane quorum.
- Keep `init.sh.tpl` for first boot only.
- Put running host configuration in Ansible.
- Put Kubernetes workload changes behind ArgoCD.
- Do not re-run `argocd-bootstrap` after root ArgoCD bootstrap.
- Do not mutate host state manually over SSH unless it is break-glass recovery.
