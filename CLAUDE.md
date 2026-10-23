# CLAUDE.md

Guidance for Claude Code (and other agents via the `AGENTS.md` symlink) in this repository.

## What this repository is

A self-managed k3s cluster on Hetzner Cloud. OpenTofu declares the servers, ArgoCD reconciles Kubernetes state, Ansible manages node files, and Go holds the operator tools.

| Path | Content |
|------|---------|
| `infra/` | OpenTofu: servers, network, firewall, API load balancer, Cloudflare tunnel/tokens/cache rules, R2 buckets. Writes `infra/kubeconfig.yaml`. |
| `nodes/` | Declarative k3s node files. Ansible copies this tree to `/etc/rancher/k3s/`. |
| `ansible/` | Playbooks, the `baseline` role, and a dynamic inventory that reads OpenTofu state through SOPS. |
| `cmd/opsctl`, `internal/` | Go operator toolkit (verification commands). |
| `kubernetes/bootstrap/` | helmfile + SOPS secrets, run **once** on a new cluster. |
| `kubernetes/base/` | ArgoCD `Application`s in 4 groups: `infra/`, `platform/`, `monitoring/`, `apps/`. |
| `kubernetes/components/` | Kustomize components; each adds an Application or raw resources to the overlay. |
| `kubernetes/overlays/prod/` | The production overlay ArgoCD reads. |
| `docs/specs/` | Committed designs and ADRs. |
| `docs/plans/` | Local plans, git-ignored. Never commit a plan. |

The git remote (`git@github.com:arunanshub/devops.git`) is also the URL ArgoCD reads. Multi-source apps reference values as `$values/kubernetes/base/<group>/<app>/values.yaml`.

## Commands

Run `mise install` once; `mise.toml` declares every CLI and `mise.lock` pins versions. mise sets `KUBECONFIG` inside the repo only — from another directory (e.g. a scratchpad), pass `--kubeconfig infra/kubeconfig.yaml` or kubectl hits whatever context is current. `kubeseal` 0.36.0 must match the in-cluster sealed-secrets controller.

The `Justfile` is the operator entrypoint (`just --list`). It exports `KUBECONFIG` and `K8S_API_ENDPOINT` to all recipes.

### Go toolkit

```bash
just build                    # build bin/opsctl
just opsctl --help            # all subcommands
go test -race -count=1 ./...  # all tests
go test -race -run TestName ./internal/mtu/
./custom-gcl run ./...        # lint
./custom-gcl fmt --diff       # format check
```

The linter is a **custom** golangci-lint build with the nilaway plugin (`.custom-gcl.yaml`). Build it with `go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.13.1` then `golangci-lint custom`. Stock golangci-lint gives different results.

Go tests in `internal/` assert invariants over `kubernetes/` YAML, so a YAML-only change still needs `go test ./...`.

### Verification (all exit non-zero on failure)

```bash
just cluster-verify      # nodes Ready + adoption invariant + MTU stack
just verify-mtu          # VXLAN+WireGuard MTU chain
just verify-adoption     # helmfile release == adopting ArgoCD Application (also in CI)
just verify-node-config  # nodes/ keys against the pinned k3s and kubelet schemas (also in CI)
just opsctl get-vpa      # VPAs whose updateMode is not the expected one
```

### Ansible

```bash
just ansible-setup                 # once: uv sync + galaxy collections
just ansible-inventory             # print the inventory graph
just ansible-check <playbook>      # --check --diff
just ansible-converge <playbook>   # rolling apply, one node per Runner job, stops on first failure
```

Runner evidence goes to `.artifacts/ansible/`.

### Manifest validation

```bash
kustomize build kubernetes/overlays/prod | kubeconform --strict --ignore-missing-schemas --summary \
  --schema-location default \
  --schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

CI and the lefthook `kustomize-validate` hook run the same command — keep them in sync.

### Pre-commit and commits

`lefthook.yml` runs: `custom-gcl fmt`/`run`, `go mod tidy`, `tofu fmt`/`validate`, `gitleaks`, `just --fmt`, `shellcheck`, `yamlfmt`, `ansible-lint`, `opsctl verify-node-config`, `kustomize-validate`.

Commits are SSH-signed with a passphrase-protected key. If signing fails, tell the user (they can load the key into the agent). Never use `--no-gpg-sign`.

## Bootstrap order (clean cluster)

Steps 3–5 are one-shots and must run in order. `docs/bootstrap-pitfalls.md` covers each failure.

1. `just apply` — OpenTofu creates servers and the API LB; cloud-init runs `infra/scripts/init.sh.tpl` and writes `infra/kubeconfig.yaml`.
2. `just argocd-bootstrap` — applies the hcloud Secret, then `helmfile apply` installs Gateway API CRDs and hccm before Cilium, then ArgoCD.
3. `just argocd-ssh-bootstrap` — ArgoCD repository SSH key.
4. `just restore-sealed-secrets-key` — sealed-secrets master key.
5. `just argocd-root-bootstrap` — applies `kubernetes/root-application.yaml`; ArgoCD owns the cluster from here.

## Key patterns

### helmfile → ArgoCD adoption

helmfile installs Cilium, hccm, and ArgoCD; ArgoCD then adopts them. Adoption must be a no-op diff under `ServerSideApply=true`:

- `helm.releaseName` in the Application must equal the helmfile release `name`. It drives the `app.kubernetes.io/instance` selector label, and selectors are immutable — a mismatch permanently fails on `Deployment.spec.selector`.
- The bootstrap values file and the ArgoCD values file must render identical manifests. The bootstrap file may be `.yaml.gotmpl` (reads `K8S_API_ENDPOINT` from env); the ArgoCD file holds the literal. **Edit both together** (e.g. both Cilium values files).

`just verify-adoption` checks this; CI runs it on every push.

### SOPS file names

`.sops.yaml` encrypts paths matching `(\w+\.)?(secrets|sops)\.ya?ml$`, so name secrets `*.sops.yaml` / `*.secrets.yaml` (sops then refuses to save plaintext there). Before encrypting a Secret from `kubectl get -o yaml`, strip `creationTimestamp`, `resourceVersion` (apply conflict), `uid`, and `ownerReferences` (points at a UID a new cluster lacks → GC deletes the Secret).

### ArgoCD sync waves

`-2` AppProject · `-1` ArgoCD self-management · `1` Cilium · `2` hccm (and anything needing Cilium CRDs) · `0` everything else.

### Add a new app

Pick the group: `infra/` (foundations), `platform/` (shared services), `monitoring/`, `apps/` (workloads), or a `components/` add-on.

1. Create `kubernetes/base/<group>/<app>/application.yaml` and `values.yaml`.
2. Add the path to `kubernetes/base/<group>/kustomization.yaml`.
3. Add the chart `repoURL` to `sourceRepos` in the group's `appproject.yaml`, and the namespace to `destinations` if missing.
4. Commit; ArgoCD reads it through `kubernetes/overlays/prod`.

A component is `kubernetes/components/<name>/kustomization.yaml`, listed under `components:` in the prod overlay. One directory holds one workload — put two resources of the same kind in separate directories.

## Node configuration

`nodes/all/` goes to every node, `nodes/control-plane/` to control planes. `ansible/playbooks/k3s-config.yml` is the **only** transport for this tree:

- It is a one-shot. Never import it into `site.yml` — a config change restarts k3s, which must stay an explicit operator action.
- `serial: 1` keeps etcd at 2/3 quorum; `max_fail_percentage: 0` stops the play and the `rescue` block restores the previous config.
- File removal is not automatic: delete from `nodes/`, add an explicit `state: absent` task for one release, then remove the task.
- The Node Ready gate can false-pass during the ~40 s node-monitor grace period. The `verify-kubelet-config` probe of the live kubelet is the load-bearing gate.
- Pass declared values to shell verifications through environment variables, never by interpolation.

Run `just ansible-check k3s-config` first, then `just ansible-converge k3s-config`.

## Network architecture

- The Hetzner Cloud Network is IPv4 only. Servers also have public IPv6 on `eth0`.
- k3s runs with `flannel-backend: none`, `disable-kube-proxy: true`, `disable-cloud-controller: true`. Cilium is the CNI and the kube-proxy replacement (socket LB, BPF host routing, BPF masquerade).
- **VXLAN tunnel mode is required**: the Hetzner network cannot carry the pod CIDRs of multiple ClusterMesh clusters. hccm still provides LoadBalancer services and node labels, but no pod routes.
- WireGuard encrypts pod-to-pod traffic between nodes (`persistentKeepalive: 25s`); the traffic flows over `enp7s0`. `nodeEncryption: true` is a **no-op** (all 3 nodes carry the default opt-out label `node-role.kubernetes.io/control-plane`). Never force it on — it causes a key-rotation deadlock, and Cilium v1.22 removes the option.
- **Pods use netkit (Layer 3)**, `bpf.datapathMode: netkit`. A node cannot switch between veth and netkit in place: changing the mode needs a drain and a reboot of each node.
- **MTU is critical.** `enp7s0` 1450 → `cilium_wg0` 1355 (−95 WireGuard) → overlay route clamp 1305 (−50 VXLAN). Pod `eth0` stays 1450. PMTUD runs in `always` mode so oversized UDP/ICMP gets ICMP feedback instead of a silent drop. Run `just verify-mtu` after any Cilium change; see `docs/cilium-mtu-overlay-networking.md`.
- The Hetzner virtio NICs have 1 queue and no UDP-tunnel offload, so VXLAN+WireGuard costs real kernel CPU under load. BIG TCP is not possible (needs no tunnel and no encryption), and RPS does not help (2 WireGuard flows per node).
- Cilium agents reach the API server at `K8S_API_ENDPOINT` (default `10.0.0.100`, the private Hetzner LB in front of all control planes).
- Admin access uses the bootstrap control plane's public IPv6; `infra/firewall.tf` gates public `6443` on `var.home_ip`. The API LB's public IPv4 is in the k3s TLS SANs for a future public-LB admin path, not the current kubeconfig endpoint.

## Doc-backed changes only (hard rule)

Never apply an infra config change from memory or assumption. Verify the exact flag, field, value, or behavior against current upstream docs for the running version (Context7, exa, `--help`, `kubectl explain`, the live CRD) **before** shipping. This is mandatory for k3s, the kubelet, Cilium, chart values, and ArgoCD. No doc URL or live output → don't act.

Two traps:

- A `kubelet-arg` is valid only if the kubelet exposes it as a **CLI flag**. Many KubeletConfiguration fields (e.g. `maxParallelImagePulls`) are not, and k3s then crash-loops with `unknown flag`. `--check`, `ansible-lint`, and `helm template` cannot catch it; only the restart does.
- To delete a chart's **default** values key, set it to `null` — omitting it lets the default merge back. ArgoCD "Synced" does not prove a values change took effect; check the live object.

## Things not to do

- Re-run `just argocd-bootstrap` after the root Application exists (helmfile and ArgoCD fight over resources).
- Commit `kubeconfig.yaml` or anything in `docs/plans/`.
- Change `helm.releaseName` on a live Application (immutable selector; the Deployment must be deleted and recreated).
- Echo a passphrase before piping it to `kubeseal` — pipe it directly.
- Change the kustomize source path in `kubernetes/root-application.yaml` in the same commit that moves the directories. ArgoCD reads the source from the in-cluster object; if the old `kustomization.yaml` is gone it falls back to plain-directory mode, applies every YAML it finds, and with `prune: true` can delete every app and the root. Run `just argocd-root-bootstrap` **first**, then push the commit that removes the old entry point (`docs/kustomize-overlay-restructure.md`).
- Run the Ansible inventory during a `tofu apply` (no per-node guard for an empty IPv6 → `ansible_host: ""`).
- Re-enable ArgoCD auto-sync before a deleted PVC fully disappears (the volume can rebind to the old claim).

## Files worth reading once

- `docs/bootstrap-pitfalls.md` — bootstrap failures with diagnosis and fix
- `docs/cilium-mtu-overlay-networking.md` — the VXLAN + WireGuard MTU postmortem
- `docs/runbook.md`, `docs/backup-restore.md` — operator procedures
- `docs/k3s-checklist.md` — node and k3s checks
- `ansible/playbooks/k3s-config.yml` — the node config transport and its safety gates
- `kubernetes/bootstrap/helmfile.yaml` — bootstrap order and the `needs:` graph
- `infra/scripts/init.sh.tpl` — the k3s install script
- `Justfile` — every operator command
