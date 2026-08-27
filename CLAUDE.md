# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## RULE 1 — Write all English in ASD-STE100

This rule is above every other rule in this file. It has no exceptions.

Write **all** text in ASD-STE100 (Simplified Technical English). This includes:

- Chat replies to the user
- Code comments
- Commit messages and PR descriptions
- Documents under `docs/`, specs, ADRs, and runbooks
- YAML comments, Justfile comments, and Go doc comments
- Alert descriptions and dashboard text

Apply these rules:

- Write short sentences. Use a maximum of 20 words in an instruction. Use a maximum of 25 words in a description.
- Write one fact or one instruction in one sentence.
- Use the active voice. Write "ArgoCD applies the manifest". Do not write "the manifest is applied".
- Use the present tense. Do not use the future tense for behavior that is always true.
- Start an instruction with the verb.
- Use one word for one meaning. Do not use a synonym for variety.
- Use simple words. Write "use", not "utilize". Write "start", not "initiate". Write "before", not "prior to".
- Use articles. Write "the pod", not "pod".
- Write the noun again. Do not use a pronoun when the reference is not clear.
- Do not use metaphors, idioms, or literary style.
- Give a reason in a separate sentence. Do not join a reason to an instruction with a long clause.
- Use a list when there is more than one step or more than one fact.

Do not write in Oxford or academic style. This is engineering text, not literature.

**Bad:** "Given that the Cilium agents, which are responsible for programming the datapath, must reach the API server, one would ideally want to ensure the endpoint is available prior to bootstrapping."

**Good:** "The Cilium agents must reach the API server. The API server must be available before you start the bootstrap. `K8S_API_ENDPOINT` gives the address."

## What this repository is

This repository holds a self-managed k3s cluster on Hetzner Cloud. OpenTofu declares the servers. ArgoCD reconciles the Kubernetes state. Ansible manages the node files. Go holds the operator tools.

| Path | Content |
|------|---------|
| `infra/` | OpenTofu. Servers, network, firewall, API load balancer, Cloudflare tunnel, Cloudflare tokens, R2 buckets. It writes `infra/kubeconfig.yaml`. |
| `nodes/` | Declarative k3s node files. Ansible copies this tree to `/etc/rancher/k3s/` on the nodes. |
| `ansible/` | Playbooks and the dynamic inventory. The inventory reads the OpenTofu state through SOPS. |
| `cmd/opsctl`, `internal/` | The Go operator toolkit. It holds the verification commands. |
| `kubernetes/bootstrap/` | helmfile and SOPS secrets. These run **one time** on a new cluster. |
| `kubernetes/base/` | ArgoCD `Application` manifests in 4 groups: `infra/`, `platform/`, `monitoring/`, `apps/`. |
| `kubernetes/components/` | Kustomize components. Each one adds an Application or raw resources to the overlay. |
| `kubernetes/overlays/prod/` | The production overlay. ArgoCD reads this path. |
| `docs/specs/` | Committed designs and ADRs. |
| `docs/plans/` | Local plans. Git ignores this directory. Do not commit a plan. |

The git remote is `git@github.com:arunanshub/devops.git`. ArgoCD reads the same URL. The multi-source `$values` pattern points at paths like `$values/kubernetes/base/infra/<app>/values.yaml` in this repository.

## Commands

Run all commands inside `devbox shell`. `devbox.json` pins every CLI. `kubeseal@0.36.0` must match the sealed-secrets controller in the cluster.

The `Justfile` is the operator entrypoint. Run `just --list` to see every recipe. The Justfile exports `KUBECONFIG` and `K8S_API_ENDPOINT` to all recipes.

### Go toolkit

```bash
just build                    # build bin/opsctl
just opsctl --help            # show all subcommands
go test -race -count=1 ./...  # run all tests
go test -race -run TestName ./internal/mtu/   # run one test
./custom-gcl run ./...        # lint
./custom-gcl fmt --diff       # check format
```

The linter is a **custom** golangci-lint build. It includes the nilaway plugin. `.custom-gcl.yaml` declares it. Build it with `go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.13.1` and then `golangci-lint custom`. Git ignores the `custom-gcl` binary. Stock golangci-lint does not give the same result.

### Verification

```bash
just cluster-verify      # nodes Ready + adoption invariant + MTU stack
just verify-mtu          # VXLAN+WireGuard MTU chain
just verify-adoption     # helmfile release == adopting ArgoCD Application (also in CI)
just verify-node-config  # nodes/ keys against the pinned k3s and kubelet schemas (also in CI)
just opsctl get-vpa      # VPAs whose updateMode is not the expected one
```

Every verification command exits non-zero on failure.

### Ansible

```bash
just ansible-setup                 # one time: uv sync + galaxy collections
just ansible-inventory             # print the inventory graph
just ansible-check <playbook>      # --check --diff
just ansible-converge <playbook>   # rolling apply, one node per Runner job
```

`ansible-converge` runs one Runner job per node. It stops on the first non-zero result. Runner evidence goes to `.artifacts/ansible/`.

### Manifest validation

```bash
kustomize build kubernetes/overlays/prod | kubeconform --strict --ignore-missing-schemas --summary \
  --schema-location default \
  --schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

CI and the lefthook `kustomize-validate` hook run the same command. Keep the two in sync.

### Pre-commit

`lefthook.yml` runs these hooks: `custom-gcl fmt`/`run`, `go mod tidy`, `tofu fmt`/`validate`, `gitleaks`, `just --fmt`, `shellcheck`, `yamlfmt`, `ansible-lint`, `opsctl verify-node-config`, and `kustomize-validate`.

### Commits

The user signs commits with an SSH key. The key has a passphrase. The agent has no TTY and no askpass. **The agent cannot commit.**

Give the command to the user instead. Use this form:

```
! git commit -F <path-to-message-file>
```

Never use `--no-gpg-sign`.

## Bootstrap order

These are the steps for a clean cluster. Steps 3 to 5 are one-shots. They must run in this order. `docs/bootstrap-pitfalls.md` describes each failure.

1. `just apply` — OpenTofu creates the servers and the API load balancer. Cloud-init runs `infra/scripts/init.sh.tpl`. It writes `infra/kubeconfig.yaml`.
2. `just argocd-bootstrap` — a dependency recipe applies the hcloud Secret. Then `helmfile apply` installs the Gateway API CRDs and hccm before Cilium. Then it installs ArgoCD.
3. `just argocd-ssh-bootstrap` — apply the ArgoCD repository SSH key.
4. `just restore-sealed-secrets-key` — apply the sealed-secrets master key.
5. `just argocd-root-bootstrap` — apply `kubernetes/root-application.yaml`. ArgoCD then reconciles everything.

After step 5, ArgoCD owns the cluster.

## Two patterns to know

### helmfile to ArgoCD adoption

helmfile installs Cilium, hccm, and ArgoCD. ArgoCD then adopts them through the `Application` manifests. The adoption must produce a no-op diff under `ServerSideApply=true`. Two conditions make this true:

- `helm.releaseName` in the `Application` must equal the helmfile release `name`. Helm derives the `app.kubernetes.io/instance` label from this name. That label is a selector. Selectors are immutable. A mismatch causes a permanent failure on `Deployment.spec.selector`.
- The bootstrap values file and the ArgoCD values file must render identical manifests. The bootstrap file can be `.yaml.gotmpl`. helmfile renders it and reads `K8S_API_ENDPOINT` from the environment. The ArgoCD file is plain YAML with the literal value. Both must give the same output.

`just verify-adoption` checks this invariant. CI runs it on every push.

### SOPS file names

`.sops.yaml` encrypts any path that matches `(\w+\.)?(secrets|sops)\.ya?ml$`. Name every secret file `*.sops.yaml` or `*.secrets.yaml`. `sops` refuses to save plaintext to those paths. This prevents an accidental commit.

Remove the runtime metadata before you encrypt a Secret manifest. Remove `creationTimestamp`, `resourceVersion`, `uid`, and `ownerReferences`. `kubectl get -o yaml` adds these fields. `resourceVersion` causes an apply conflict. `ownerReferences` points at a UID that a new cluster does not have. The garbage collector then deletes the Secret after the apply.

## ArgoCD sync waves

The `argocd.argoproj.io/sync-wave` annotation sets the order. This repository uses these values:

- `-2`: `AppProject`. It must exist before the child Applications that reference it.
- `-1`: the ArgoCD self-management Application.
- `1`: Cilium. The network must start before any workload that needs pod networking.
- `2`: hccm. It needs Cilium.
- `0` (default): everything else.

## Add a new app to ArgoCD

Choose the group first. `base/infra/` holds cluster foundations. `base/platform/` holds shared services. `base/monitoring/` holds observability. `base/apps/` holds user workloads. `components/` holds an add-on that the overlay switches on.

1. Create `kubernetes/base/<group>/<app>/application.yaml` and a `values.yaml` beside it.
2. Add the new path to `kubernetes/base/<group>/kustomization.yaml`.
3. Add the chart `repoURL` to the `sourceRepos` list in that group's `appproject.yaml`.
4. Add the namespace to the `destinations` list if the AppProject does not have it.
5. Commit. ArgoCD reads the change through `kubernetes/overlays/prod`.

For a component, create `kubernetes/components/<name>/kustomization.yaml` and add the path to `kubernetes/overlays/prod/kustomization.yaml` under `components:`.

Put two resources of the same kind in separate directories. One directory holds one workload.

## Node configuration

`nodes/` holds the desired k3s node files as plain files. `nodes/all/` goes to every node. `nodes/control-plane/` goes to the control planes only.

`ansible/playbooks/k3s-config.yml` is the **only** transport for this tree. Read these facts before you use it:

- The playbook is a one-shot. Do **not** import it into `site.yml`. A config change restarts k3s. That restart must stay an explicit operator action.
- It restarts one node at a time (`serial: 1`). etcd keeps a 2 of 3 quorum.
- A failure stops the play (`max_fail_percentage: 0`). The `rescue` block restores the previous config on that node.
- A file removal is not automatic. Delete the file from `nodes/`, then add an explicit `state: absent` task for one release, then remove that task.
- The Node Ready gate can give a false pass. The node-monitor grace period is about 40 seconds. The `verify-kubelet-config` step probes the live kubelet and is the load-bearing gate.
- Pass a declared value to a shell verification through an environment variable. Never interpolate the value into the shell string. Quoting breaks.

Use `just ansible-check k3s-config` first. Then use `just ansible-converge k3s-config`.

## Network architecture

- The Hetzner Cloud Network is IPv4 only. Hetzner private networks do not carry IPv6. The servers still have IPv6 on the public interface.
- k3s runs with `flannel-backend: none`, `disable-kube-proxy: true`, and `disable-cloud-controller: true`.
- Cilium replaces all three. It is the CNI. It replaces kube-proxy (`kubeProxyReplacement: true`). It uses VXLAN tunnel mode (`routingMode: tunnel`, `tunnelProtocol: vxlan`).
- VXLAN is required. The Hetzner network cannot carry the pod CIDRs of more than one cluster in a ClusterMesh. Native routing breaks cross-cluster pod traffic.
- hccm still runs. It gives the cloud-provider integration: LoadBalancer services and node labels. It does not program pod-CIDR routes. VXLAN carries the cross-node pod traffic.
- WireGuard encrypts the pod-to-pod traffic between nodes (`encryption.type: wireguard`, `persistentKeepalive: 25s`). WireGuard runs over IPv6 between the nodes.
- `nodeEncryption: true` is set, but it is a **no-op**. The default opt-out label is `node-role.kubernetes.io/control-plane`. All 3 nodes carry that label. Pod-to-pod traffic is still encrypted. Do not force node encryption on. It causes a key-rotation deadlock. The option is deprecated and Cilium v1.22 removes it.
- **MTU is critical.** The cross-node path MTU is 1450 (Hetzner NIC) − 95 (WireGuard) − 50 (VXLAN) = **1305 bytes**. `cilium_wg0` is 1450 − 95 = **1355**. The overlay route clamp is 1355 − 50 = 1305. Cilium ≥ 1.20.0-pre.3 reserves 95 bytes. Cilium ≤ 1.20.0-pre.2 reserved 80 bytes, so the chain was 1320 with `cilium_wg0` at 1370.
- Cilium PMTUD uses `always` mode. An oversized UDP or ICMP packet then gets ICMP feedback. Without it the packet drops in silence.
- Run `just verify-mtu` after any Cilium change. Read `docs/cilium-mtu-overlay-networking.md` for the full analysis.
- The Cilium agents reach the API server at `K8S_API_ENDPOINT` (default `10.0.0.100` = `local.lb_private_ip`). This is the private Hetzner load balancer in front of all control planes.
- Admin access uses the public IPv6 of the bootstrap control plane. `infra/firewall.tf` gates public `6443` on `var.home_ip`. The public IPv4 of the API load balancer is in the k3s TLS SANs. That is for a future switch to a public-LB admin path. It is not the current kubeconfig endpoint.

## Doc-backed changes only (hard rule)

Do **not** apply an infra config change from memory or assumption. Verify the exact flag, field, value, or behavior against the current upstream docs **before** you ship it. Use Context7 or exa pinned to the running version. Use the `--help` output of the tool. Use the live API (`kubectl explain`, the live CRD). This rule is mandatory for k3s, the kubelet, Cilium, chart values, and ArgoCD behavior. If you cannot give a doc URL or live-command output for a claim, do not act on the claim.

Two specific traps:

- A `kubelet-arg` is valid only if the kubelet exposes it as a **CLI flag**. Many KubeletConfiguration *fields* are not CLI flags. `maxParallelImagePulls` is one example. k3s then crash-loops with `unknown flag`. `--check`, `ansible-lint`, and `helm template` cannot catch a runtime flag rejection. Only the restart catches it. A successful render is not proof.
- To delete a **default** key from a Helm chart values map, set the key to `null`. If you omit the key, the chart default merges back in. An ArgoCD "Synced" status is not proof that a values change took effect. Check the live object.

This rule exists because an unverified `--max-parallel-image-pulls` kubelet-arg crash-looped k3s on cp-1 on 2026-06-19. The safety net held. The failure was avoidable.

## Things not to do

- Do not re-run `just argocd-bootstrap` after the root Application exists. helmfile and ArgoCD then fight for the same resources.
- Do not commit `kubeconfig.yaml`. `.gitignore` already excludes it.
- Do not commit a file from `docs/plans/`. Git ignores that directory on purpose.
- Do not build a SOPS-encrypted Secret from `kubectl get -o yaml` without removing the runtime metadata first.
- Do not change `helm.releaseName` on a live ArgoCD Application. The selector is immutable. You must delete and recreate the `Deployment`.
- Do not echo a passphrase before you pipe it to `kubeseal`. Pipe the value directly. An echo can reach a log.
- Do not change the kustomize source path in `kubernetes/root-application.yaml` in the same commit that moves the directories. ArgoCD reads the source from the in-cluster Application object, not from the file. If the in-cluster source points at the old path and the old `kustomization.yaml` is gone, ArgoCD uses plain-directory mode. It then applies every YAML file that it finds, including `root-application.yaml`. With `prune: true` it can delete every managed app and the root Application. Correct order: run `just argocd-root-bootstrap` **first**, then push the commit that removes the old entry point. See `docs/kustomize-overlay-restructure.md`.
- Do not run the Ansible inventory during a `tofu apply`. The inventory has no per-node guard for an empty IPv6 address. `ansible_host` then becomes an empty string.
- Do not disable ArgoCD auto-sync and then re-enable it before a PVC fully disappears. The volume can rebind to the old claim.

## Files to read one time

- `docs/bootstrap-pitfalls.md` — bootstrap failures, each with a diagnosis and a fix
- `docs/cilium-mtu-overlay-networking.md` — the VXLAN and WireGuard MTU postmortem
- `docs/runbook.md` and `docs/backup-restore.md` — operator procedures
- `docs/k3s-checklist.md` — node and k3s checks
- `ansible/playbooks/k3s-config.yml` — the node config transport and its safety gates
- `kubernetes/bootstrap/helmfile.yaml` — the bootstrap order and the `needs:` graph
- `infra/scripts/init.sh.tpl` — the k3s install script
- `Justfile` — every operator command
