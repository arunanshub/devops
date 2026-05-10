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

## Fresh Cluster Bootstrap

Run in this order:

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

## Hard Rules

- Read `just plan` before applying.
- Preserve control-plane quorum.
- Keep `init.sh.tpl` for first boot only.
- Put running host configuration in Ansible.
- Put Kubernetes workload changes behind ArgoCD.
- Do not re-run `argocd-bootstrap` after root ArgoCD bootstrap.
- Do not mutate host state manually over SSH unless it is break-glass recovery.
