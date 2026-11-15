# Node Configuration Management ADR

Date: 2026-05-10

## Status

Accepted and implemented for in-place node convergence. Node replacement and
membership automation remain deferred.

## Context

The cluster is now moving toward a three-node k3s control plane on Hetzner with
embedded etcd. OpenTofu owns the Hetzner infrastructure: servers, network, API
load balancer, firewalls, and local kubeconfig generation. ArgoCD owns
Kubernetes workloads after bootstrap.

The missing layer is host configuration management.

Today, too much node state is encoded in `infra/scripts/init.sh.tpl`, which is
rendered into `hcloud_server.user_data`. That creates two problems:

- `user_data` is creation-time data. Changing it causes server replacement,
  even for changes that are really "make the running machine converge to this
  state" changes.
- OpenTofu has resource create/destroy semantics, not safe rolling convergence
  semantics for a live etcd-backed control plane.

This is not a failure of OpenTofu. It is the wrong layer for the job.

## Decision

Introduce Ansible as the repo's layer-2 configuration management system.

The target stack becomes:

```text
OpenTofu       -> infrastructure objects
cloud-init     -> minimal first-boot transport/bootstrap
Ansible        -> host OS and k3s node-state convergence
Kubernetes     -> cluster runtime
ArgoCD         -> Kubernetes workload convergence
SUC + kured    -> k3s upgrades and reboot orchestration
```

Ansible will be installed through `devbox.json`. Devbox already uses Nix
internally, so adding Ansible there keeps the operator toolchain pinned in the
same place as OpenTofu, hcloud, helmfile, SOPS, and kubeseal.

Automation over SSH is allowed. Manual SSH that mutates machine state is not.

The operating rule is:

```text
Manual SSH for diagnosis: acceptable when necessary.
Manual SSH for state changes: break-glass only.
Ansible SSH for audited convergence: normal path.
```

This is the host equivalent of not using `kubectl edit` for resources that
ArgoCD should own.

## What Moves Out Of init.sh

`init.sh.tpl` should shrink toward first-boot responsibilities only:

- create the initial k3s config location
- write enough k3s config for the node to install and join correctly
- install k3s, or install the minimum needed for Ansible to install k3s
- handle bootstrap-only waiting required for initial kubeconfig generation

Fleet baseline belongs in Ansible:

- unattended-upgrades configuration
- host packages
- sysctls and kernel modules
- host-level agents, if any are intentionally required
- config files under `/etc` that are not pure first-boot identity
- future host-level access tooling, if explicitly adopted

If a future change feels like "I wish this had been present from the start",
that is a signal for Ansible, not `init.sh.tpl`.

## OpenTofu user_data Policy

Once `init.sh.tpl` has been reduced to first-boot bootstrap only,
`hcloud_server.nodes` should ignore future `user_data` drift:

```hcl
lifecycle {
  ignore_changes = [user_data]
}
```

Reasoning:

- `user_data` is not live machine state after cloud-init has run.
- Keeping it in the normal OpenTofu diff path creates accidental mass
  replacement risk.
- Real node replacement should be explicit and one node at a time.
- Ongoing host state should be represented in Ansible, not in cloud-init.

This is not a retreat from determinism. It is a statement that the source of
truth for running host state moves from cloud-init to Ansible.

Ordering matters. Before `init.sh.tpl` has been reduced and the Ansible
convergence path has been proven, ignoring `user_data` would hide drift that is
still meaningful. The `ignore_changes = [user_data]` change becomes safe only
when `user_data` is genuinely creation-time-only and Ansible owns the running
host state. The two changes must land together.

## Ansible Structure

Use separate playbooks or clearly separated roles for different risk classes.

### Baseline Convergence

Baseline convergence is safe to run repeatedly across the fleet with
`serial: 1`.

It may manage:

- packages
- unattended-upgrades
- general host config
- non-k3s services
- safe config files

It must not remove or recreate k3s membership.

### K3s Config Convergence

K3s config convergence may manage files such as:

- `/etc/rancher/k3s/config.yaml`
- `/etc/rancher/k3s/config.yaml.d/*.yaml`
- kubelet drop-in config, if needed later

Control-plane restart must be gated and serial. A handler that restarts all
control-plane nodes together is forbidden.

Before moving to the next control-plane node, the workflow must prove:

- the current node is Ready again
- the API is reachable
- Cilium is healthy enough for normal scheduling
- the control plane still has quorum

### K3s Membership Workflows

K3s membership is allowed to be orchestrated by Ansible, but it must not be part
of default baseline convergence.

Membership workflows are special-purpose commands for:

- initial cluster bootstrap
- joining new control-plane nodes
- joining worker nodes
- replacing a node
- retiring a node
- cleaning stale node registration state
- cleaning stale etcd membership when required

These workflows are closer to database migrations than package installation.
They must be explicit, health-gated, and one node at a time.

The bootstrap-versus-join decision belongs here, not in OpenTofu. The first
server is special only when creating a brand-new cluster with no healthy peer
reachable through the API load balancer. After the cluster exists, every fresh
server, including a replacement for the original bootstrap node, should join
through the stable API endpoint. OpenTofu should describe that a node exists;
Ansible membership orchestration should decide whether the current operation is
first-cluster bootstrap or join.

## K3s Membership Failure Modes

These failure modes must be documented in the implementation and guarded by
automation where practical.

### Accidental Second Cluster

Only the first server of a new cluster should use `cluster-init: true`.

After a cluster exists, a fresh replacement node must join with `server:
https://10.0.0.100:6443`. A fresh VM has no existing etcd data on disk, so
incorrectly applying `cluster-init: true` can initialize a separate datastore
instead of joining the existing cluster.

The structural guard is that the membership workflow checks whether a healthy
cluster is reachable at the API load balancer. If it is reachable, the node uses
`server: https://10.0.0.100:6443`. If it is not reachable and the workflow is
explicitly a brand-new cluster bootstrap, exactly one server may use
`cluster-init: true`.

### Critical Config Mismatch

K3s requires several server flags to match across embedded-etcd servers. A
partial, ungated config rollout can prevent servers from joining or operating
correctly.

The automation must treat these as cluster-level changes, not casual per-node
edits.

### Node Registration Password Mismatch

K3s stores node identity material locally under `/etc/rancher/node` and stores
corresponding node-password secrets in `kube-system`.

If a node name is reused after local state is wiped, the old Kubernetes Node
must be deleted so K3s can clean up the node-password secret before the node
rejoins.

### Stale etcd Membership

For control-plane replacement, Kubernetes Node deletion and embedded etcd member
cleanup are related but not equivalent. The rotation workflow must verify etcd
membership and remove stale members when required.

The exact implementation command should be proven against the active k3s
version before automation is trusted.

### Quorum Loss

For a three-control-plane embedded-etcd cluster, only one control-plane node may
be disrupted at a time. Any workflow that can stop, restart, drain, delete, or
replace control-plane nodes must be serial and must stop on first failure.

## Rolling Safety Rules

All host convergence workflows must default to conservative availability.

Control-plane rules:

- run with `serial: 1`
- drain before disruptive changes when Kubernetes scheduling is affected
- do not drain if the workflow only changes safe files and does not restart k3s
- restart k3s on at most one control-plane node at a time
- wait for Ready before continuing
- verify API health before continuing
- verify quorum before continuing
- stop immediately on failure

Worker rules:

- run with `serial: 1` at first
- larger batches may be considered later
- drain before disruptive changes
- uncordon only after node health is restored

Destructive infrastructure rules:

- a normal `tofu apply` must not replace multiple control-plane nodes
- explicit replacement must target one node at a time
- future replacement workflow should use `tofu apply -replace='hcloud_server.nodes["<node>"]'`
  without `-target`, so the selected resource is marked for replacement within
  a normal full-graph plan
- replacement must be preceded by cluster health checks
- replacement must be followed by node, Cilium, API, and etcd checks

## Relationship With Existing SUC And kured

System Upgrade Controller remains responsible for k3s upgrades. The current
server Plan already uses `concurrency: 1` and `cordon: true`.

kured remains responsible for rebooting nodes when the OS requires a reboot.
Its maintenance window keeps reboots boring and observable.

Ansible does not replace SUC or kured.

Ansible owns host desired state. SUC owns k3s version upgrades. kured owns
reboot execution when a reboot is required.

## Inventory Source

Use the pinned upstream `hetzner.hcloud` dynamic inventory plugin. OpenTofu
applies non-secret `cluster`, `node_key`, and `node_role` labels to the existing
protected servers; the plugin selects and groups them directly from Hetzner's
API. The token remains SOPS-managed.

This replaces the earlier OpenTofu-JSON transformer decision. It removes the
custom Go inventory package and avoids coupling routine node convergence to a
local state file.

The rendered Ansible hostname remains the Kubernetes node name:
`hetzner-k3s-<node-key>`.

## Execution Evidence

Ansible Runner is the execution substrate. The public converge command starts
one Runner job per sorted node and stops on any nonzero exit, including an
unreachable host. Artifacts are retained locally under `.artifacts/ansible/`.
Playbooks additionally keep `serial: 1`, `forks = 1`, preflight, and postflight
as defense in depth.

## Secrets

Secrets must continue to flow through SOPS or existing secret-management
patterns.

Ansible must not introduce plaintext secrets into the repo.

Examples:

- k3s token remains secret material
- hcloud token remains secret material
- future host-agent credentials must be stored encrypted

## Previous Claude Justfile Replacement Recipe

A previous `replace-node` recipe proposed in the Justfile was directionally
useful but should not be accepted as-is.

Keep the idea:

- one node at a time
- cordon and drain
- explicit replacement
- wait for Ready
- post-flight verification

Do not keep that implementation as the blessed path because:

- it deletes the Kubernetes Node before proving etcd membership handling
- it uses `tofu apply -auto-approve`
- it relies on `-target`; the future workflow should use `-replace` inside a
  normal full-graph plan instead
- it treats bootstrap-node safety through `cluster_initialized`, which still
  causes a replacement-sensitive user_data transition
- its etcd verification is only a printed SSH hint
- it belongs in the future membership workflow, not in today's generic Justfile
  surface

Recommendation: keep the recipe reverted. Reintroduce a stricter replacement
workflow after Ansible and health gates exist.

## Deferred: MicroOS

MicroOS is on the wishlist.

MicroOS would improve the host layer by making OS changes transactional and
rollback-friendly. It pairs well with Ansible because Ansible can describe the
desired state while MicroOS applies lower-level package changes through
transactional snapshots.

It is deferred because Ubuntu plus Ansible is the smaller learning step and can
be introduced without rebuilding the cluster immediately.

Future evaluation criteria:

- k3s remains comfortable on the chosen machine sizes
- package/config changes can be expressed cleanly through Ansible
- reboot flow works cleanly with kured
- rollback behavior is understood and tested

## Further Deferred: NixOS

NixOS is a deeper future goal.

It is the stronger answer for declarative, lockfile-backed, reproducible machine
state. It also requires learning Nix, flakes, deployment tooling, and a new OS
model.

It should not block the current architecture.

The current path should leave room for NixOS later by keeping clean boundaries:

- OpenTofu owns infrastructure
- Ansible owns host convergence for now
- ArgoCD owns Kubernetes workloads
- manual host mutation remains break-glass only

## Consequences

Positive:

- host state gets a real convergence layer
- `init.sh.tpl` becomes smaller and less dangerous
- routine host changes no longer imply VM replacement
- control-plane changes can be rolled safely with `serial: 1`
- manual SSH mutation is replaced by auditable automation
- future MicroOS or NixOS adoption remains possible

Negative:

- Ansible adds another tool and mental model
- Ansible is idempotent-by-discipline, not purely declarative
- SSH remains part of the automation transport
- k3s membership still requires careful special workflows
- exact etcd health/member commands must be proven before replacement
  automation is trusted

## Non-Goals

This ADR does not solve:

- multi-location or multi-AZ availability
- Kubernetes-created stateful workload durability
- PVC migration or backup semantics
- WireGuard or Tailscale admin networking
- replacing k3s with upstream Kubernetes or Talos
- bit-identical host reproducibility

Those are separate architectural decisions.

## Implementation Sketch

Initial implementation should be staged:

1. Add Ansible to `devbox.json`.
2. Add an Ansible inventory generation path from OpenTofu outputs.
3. Add a baseline playbook that manages only low-risk host state currently in
   `init.sh.tpl`.
4. Run the baseline playbook first with `--check --diff` against the existing
   nodes. Treat this as the transition audit from cloud-init side effects to
   Ansible-managed state.
5. Review the check-mode diff and confirm it matches expectations.
6. Run baseline convergence for real with `serial: 1`.
7. Move unattended-upgrades configuration from `init.sh.tpl` to Ansible.
8. Add a read-only health check recipe for nodes, Cilium, API reachability, and
   etcd membership.
9. Add `ignore_changes = [user_data]` only after `init.sh.tpl` has been reduced
   and the new Ansible path is proven.
10. Design k3s membership workflows separately.

The first implementation must not attempt to replace or rotate control-plane
nodes automatically.
