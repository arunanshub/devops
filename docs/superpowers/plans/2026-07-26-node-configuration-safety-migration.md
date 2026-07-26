# Node Configuration Safety Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove generic node-management machinery from `opsctl`, make every production node change fail closed with durable execution evidence, and preserve the existing Ubuntu/K3s/Hetzner servers in place.

**Architecture:** OpenTofu continues to own the existing protected Hetzner servers, and cloud-init continues to perform first-boot K3s installation. The standard Hetzner Ansible inventory plugin replaces the Go inventory generator; Ansible Runner replaces direct `ansible-playbook` invocation and records structured artifacts. A small cluster-specific safety role owns the only logic that cannot be supplied by a generic framework: proving all control-plane members, embedded etcd, the API, and Cilium are healthy before and after a one-node-at-a-time change.

**Tech Stack:** Ubuntu 24.04, K3s `v1.36.2+k3s1`, embedded etcd, Cilium, OpenTofu, `ansible-core`, `hetzner.hcloud`, `kubernetes.core`, Ansible Runner, SOPS, `just`, Go.

## Global Constraints

- Do not rebuild, replace, resize, delete, reset, uninstall, or recreate any existing Hetzner server.
- Do not change K3s, replace K3s, or introduce Talos.
- Keep `infra/servers.tf` protections: `delete_protection`, `rebuild_protection`, `prevent_destroy`, and `ignore_changes = [user_data]`.
- A normal node-configuration command must not invoke `tofu apply`, `tofu destroy`, `tofu -replace`, `hcloud server rebuild`, or a K3s reset/uninstall operation.
- All host convergence uses one host at a time and stops on the first failure.
- A K3s restart is allowed only when the checksum-managed configuration on that node changed.
- Production rollout requires all declared control-plane nodes healthy, the embedded-etcd membership count equal to the inventory control-plane count, all etcd endpoints healthy, the Kubernetes API ready, and Cilium healthy.
- Hetzner test-server provisioning is optional and is not part of this plan.
- Local multi-VM certification is optional and is not a prerequisite for production execution.
- Keep System Upgrade Controller responsible for K3s upgrades and kured responsible for reboots.
- Keep secrets in SOPS or environment variables; do not write tokens or private keys into inventory files or Runner artifacts.
- Retain the narrow K3s/kubelet flag validator until an equally strong upstream validation path exists. Do not replace it with YAML schema validation or Ansible check mode.

---

## Scope and File Map

### Files created

- `ansible/inventory/hcloud.yml`: standard Hetzner Cloud dynamic inventory.
- `ansible/inventory/group_vars/all.yml`: non-secret connection and cluster constants.
- `ansible/runner/env/settings`: Runner timeouts and artifact behavior.
- `ansible/roles/k3s_safety/defaults/main.yml`: certificate paths, expected member count, and probe timeouts.
- `ansible/roles/k3s_safety/tasks/control_plane.yml`: local API and embedded-etcd checks on each control plane.
- `ansible/roles/k3s_safety/tasks/cluster.yml`: Kubernetes Node and Cilium checks from the operator machine.

### Files modified

- `infra/servers.tf`: add non-secret `node_key` and `node_role` labels used by standard inventory.
- `ansible/requirements.yml`: pin `hetzner.hcloud` and the existing Kubernetes collection.
- `pyproject.toml` and `uv.lock`: add Ansible Runner and inventory-plugin runtime dependencies.
- `ansible.cfg`: force conservative defaults and point at the new inventory.
- `.gitignore`: ignore local Runner artifacts.
- `Justfile`: route convergence through Runner; expose safe preflight, check, and apply commands.
- `lefthook.yml`: reject invalid node declarations and Ansible content before commit.
- `ansible/playbooks/baseline.yml`: make `serial: 1` unconditional.
- `ansible/roles/baseline/tasks/main.yml`: install a version-compatible `etcdctl` on control-plane nodes.
- `ansible/playbooks/k3s-config.yml`: run cluster preflight before mutation and full postflight after every changed node and rollback.
- `cmd/opsctl/main.go`: remove the inventory subcommand.
- `cmd/opsctl/verify_kubelet_config.go`: accept the target node role explicitly.
- `internal/nodecfg/kubelet.go`: collect only the config layers applicable to the target role.
- `internal/nodecfg/kubelet_test.go`: prove role-aware config selection.
- `docs/runbook.md`: document the new commands, evidence location, and failure behavior.
- `docs/specs/2026-05-10-node-configuration-management-adr.md`: record the upstream-first refinement.
- `CLAUDE.md`: update the hard node-change rule and command names.

### Files deleted

- `ansible/inventory/tofu_inventory`
- `cmd/opsctl/ansible_inventory.go`
- `internal/inventory/inventory.go`
- `internal/inventory/inventory_test.go`
- `internal/inventory/load.go`

### Explicitly unchanged

- `infra/scripts/init.sh.tpl`
- Existing `hcloud_server.nodes` identities, images, server types, locations, and IPs
- K3s version and installation
- System Upgrade Controller and kured
- Talos files and migration history
- Unrelated `opsctl` commands such as MTU and ArgoCD-adoption verification

---

### Task 1: Replace the Go Inventory with the Standard Hetzner Inventory Plugin

**Files:**

- Create: `ansible/inventory/hcloud.yml`
- Create: `ansible/inventory/group_vars/all.yml`
- Modify: `infra/servers.tf`
- Modify: `ansible/requirements.yml`
- Modify: `pyproject.toml`
- Modify: `uv.lock`
- Keep temporarily: `ansible/inventory/tofu_inventory`
- Keep temporarily: `internal/inventory/*`

**Interfaces:**

- Consumes: `HCLOUD_TOKEN` from `sops exec-env infra/secrets.yaml`.
- Produces: Ansible groups `k3s_nodes`, `control_planes`, and `workers`.
- Produces host variables: `node_key`, `node_role`, `node_private_ip`, and `kubernetes_node_name`.
- Safety gate: the old inventory remains available until live parity is proven.

- [ ] **Step 1: Add stable inventory labels to each existing server**

Change the `labels` expression in `infra/servers.tf` to:

```hcl
  labels = {
    cluster   = local.cluster_name
    node_key  = each.key
    node_role = each.value.role
  }
```

- [ ] **Step 2: Prove the label change cannot replace a server**

Run:

```bash
rtk proxy sh -c "cd infra && sops exec-env secrets.yaml 'tofu plan -no-color'"
```

Expected:

```text
hcloud_server.nodes[...] will be updated in-place
Plan: 0 to add, <node-count> to change, 0 to destroy.
```

Stop immediately if the plan contains `must be replaced`, `-/+`, `destroy`, an image change, a server-type change, or a server-ID change.

- [ ] **Step 3: Apply only the reviewed in-place label update**

Run:

```bash
rtk proxy sh -c "cd infra && sops exec-env secrets.yaml 'tofu apply'"
```

At the approval prompt, re-check that the summary says `0 to add` and `0 to destroy`.

- [ ] **Step 4: Pin the upstream inventory collection**

Replace `ansible/requirements.yml` with:

```yaml
---
collections:
  - name: hetzner.hcloud
    version: "6.10.0"
  - name: kubernetes.core
    version: "6.4.0"
```

Add the inventory plugin's documented Python requirements to `pyproject.toml`:

```toml
dependencies = [
    "ansible-core>=2.21.1,<2.22",
    "python-dateutil>=2.9.0.post0,<3",
    "requests>=2.32.5,<3",
]
```

Run:

```bash
rtk uv lock
rtk proxy uv run ansible-galaxy collection install -r ansible/requirements.yml -p ansible/collections/ --force
```

Expected: both pinned collections install successfully.

- [ ] **Step 5: Add the standard dynamic inventory**

Create `ansible/inventory/hcloud.yml`:

```yaml
---
plugin: hetzner.hcloud.hcloud
label_selector: "cluster=hetzner-k3s"
connect_with: public_ipv6
group: k3s_nodes
strict: true

compose:
  node_key: hcloud_labels.node_key
  node_role: hcloud_labels.node_role
  node_private_ip: hcloud_private_ipv4
  kubernetes_node_name: hcloud_name

groups:
  control_planes: hcloud_labels.node_role in ["cp_only", "cp_worker"]
  workers: hcloud_labels.node_role == "worker"
```

Create `ansible/inventory/group_vars/all.yml`:

```yaml
---
api_lb_private_ip: "10.0.0.100"
ansible_user: root
ansible_private_key_file: >-
  {{ lookup('ansible.builtin.env', 'ANSIBLE_SSH_PRIVATE_KEY_FILE')
     | default('~/.ssh/id_ed25519', true) }}
ansible_ssh_common_args: >-
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile=infra/.ssh_known_hosts
```

- [ ] **Step 6: Compare old and new live inventories before switching**

Run:

```bash
rtk proxy sh -c "sops exec-env infra/secrets.yaml \
  'uv run ansible-inventory -i ansible/inventory/tofu_inventory --list' \
  > /tmp/old-inventory.json"
rtk proxy sh -c "sops exec-env infra/secrets.yaml \
  'uv run ansible-inventory -i ansible/inventory/hcloud.yml --list' \
  > /tmp/new-inventory.json"
rtk proxy jq -S '{
  k3s_nodes: .k3s_nodes.hosts,
  control_planes: .control_planes.hosts,
  workers: .workers.hosts,
  hostvars: (._meta.hostvars | with_entries(.value |= {
    ansible_host,
    node_key,
    node_role,
    node_private_ip,
    kubernetes_node_name
  }))
}' /tmp/old-inventory.json > /tmp/old-inventory.normalized.json
rtk proxy jq -S '{
  k3s_nodes: .k3s_nodes.hosts,
  control_planes: .control_planes.hosts,
  workers: .workers.hosts,
  hostvars: (._meta.hostvars | with_entries(.value |= {
    ansible_host,
    node_key,
    node_role,
    node_private_ip,
    kubernetes_node_name
  }))
}' /tmp/new-inventory.json > /tmp/new-inventory.normalized.json
rtk diff /tmp/old-inventory.normalized.json /tmp/new-inventory.normalized.json
```

Expected: no diff. A difference in host ordering is acceptable only after both normalized files contain exactly the same host sets and host variables.

- [ ] **Step 7: Verify SSH reachability without mutation**

Run:

```bash
rtk proxy sh -c "sops exec-env infra/secrets.yaml \
  'uv run ansible all -i ansible/inventory/hcloud.yml \
  -m ansible.builtin.ping --one-line --forks 1'"
```

Expected: every declared host returns `SUCCESS`.

- [ ] **Step 8: Commit the independently usable inventory migration**

```bash
rtk git add infra/servers.tf ansible/requirements.yml ansible/inventory/hcloud.yml \
  ansible/inventory/group_vars/all.yml pyproject.toml uv.lock
rtk git commit -m "refactor: use upstream hcloud ansible inventory"
```

---

### Task 2: Route Ansible Through Runner and Lock Conservative Defaults

**Files:**

- Create: `ansible/runner/env/settings`
- Modify: `pyproject.toml`
- Modify: `uv.lock`
- Modify: `ansible.cfg`
- Modify: `.gitignore`
- Modify: `Justfile`
- Modify: `ansible/playbooks/baseline.yml`

**Interfaces:**

- Consumes: `ansible/inventory/hcloud.yml` from Task 1.
- Produces: `.artifacts/ansible/<run-id>/status`, `rc`, `stdout`, and `job_events/`.
- Produces commands: `just ansible-inventory`, `just ansible-check <playbook>`, and `just ansible-converge <playbook>`.
- Safety invariant: Runner always receives `--forks 1`; playbooks also enforce `serial: 1`.

- [ ] **Step 1: Add the pinned Runner dependency**

Add to `pyproject.toml`:

```toml
dependencies = [
    "ansible-core>=2.21.1,<2.22",
    "ansible-runner>=2.4.3,<2.5",
    "python-dateutil>=2.9.0.post0,<3",
    "requests>=2.32.5,<3",
]
```

Run:

```bash
rtk uv lock
rtk uv sync --dev
rtk proxy uv run ansible-runner --version
```

Expected: Runner reports `2.4.3` or a compatible `2.4.x` release.

- [ ] **Step 2: Configure bounded execution and durable artifacts**

Create `ansible/runner/env/settings`:

```yaml
---
idle_timeout: 600
job_timeout: 3600
suppress_output_file: false
suppress_ansible_output: false
```

Add to `.gitignore`:

```gitignore
# Local Ansible Runner evidence; retained on the operator machine, never committed.
.artifacts/
```

- [ ] **Step 3: Make conservative Ansible behavior the repository default**

Replace `ansible.cfg` with:

```ini
[defaults]
interpreter_python = auto_silent
retry_files_enabled = False
roles_path = ansible/roles
collections_path = ansible/collections
inventory = ansible/inventory/hcloud.yml
host_key_checking = True
forks = 1

[inventory]
enable_plugins = hetzner.hcloud.hcloud, host_list, script, auto, yaml, ini, toml
```

`forks = 1` is defense in depth; disruptive playbooks must still use `serial: 1`.

- [ ] **Step 4: Make baseline serial unconditionally**

Change `ansible/playbooks/baseline.yml` to:

```yaml
---
- name: Converge baseline host configuration
  hosts: k3s_nodes
  gather_facts: true
  become: false
  serial: 1
  any_errors_fatal: true
  order: sorted
  roles:
    - baseline
```

- [ ] **Step 5: Replace direct playbook execution with Runner**

In `Justfile`, set:

```just
ansible_inventory := ansible_dir / "inventory/hcloud.yml"
ansible_runner := ansible_dir / "runner"
ansible_artifacts := justfile_dir() / ".artifacts/ansible"
```

Replace `_ansible-playbook` with:

```just
@_ansible-playbook playbook args="":
    test -f "{{ ansible_playbooks }}/{{ playbook }}.yml"
    mkdir -p "{{ ansible_artifacts }}"
    cd "{{ justfile_dir() }}" && sops exec-env "{{ infra / "secrets.yaml" }}" \
        "{{ ansible_env }} uv run ansible-runner run '{{ ansible_runner }}' \
        --project-dir '{{ justfile_dir() }}' \
        --inventory '{{ ansible_inventory }}' \
        --artifact-dir '{{ ansible_artifacts }}' \
        --rotate-artifacts 20 \
        --forks 1 \
        --playbook 'ansible/playbooks/{{ playbook }}.yml' \
        --cmdline '{{ args }}'"
```

Keep the public `ansible-check` and `ansible-converge` recipes unchanged so operator muscle memory continues to work.

- [ ] **Step 6: Verify Runner without changing a node**

Run:

```bash
rtk proxy just ansible-inventory
rtk proxy just ansible-check baseline
rtk find 'status|rc|stdout|job_events' .artifacts/ansible
```

Expected:

- Inventory lists every existing node in the correct role group.
- Check mode exits zero.
- The newest artifact directory contains `status`, `rc`, `stdout`, and `job_events/`.
- `status` contains `successful`.
- `rc` contains `0`.

- [ ] **Step 7: Commit the execution-substrate migration**

```bash
rtk git add pyproject.toml uv.lock ansible.cfg ansible/runner/env/settings \
  .gitignore Justfile ansible/playbooks/baseline.yml
rtk git commit -m "refactor: execute ansible with durable runner artifacts"
```

---

### Task 3: Add Standard Embedded-etcd, API, Node, and Cilium Safety Probes

**Files:**

- Create: `ansible/roles/k3s_safety/defaults/main.yml`
- Create: `ansible/roles/k3s_safety/tasks/control_plane.yml`
- Create: `ansible/roles/k3s_safety/tasks/cluster.yml`
- Modify: `ansible/roles/baseline/tasks/main.yml`

**Interfaces:**

- Consumes: K3s-managed etcd certificates under `/var/lib/rancher/k3s/server/tls/etcd`.
- Consumes: inventory group `control_planes`.
- Produces: reusable task files `k3s_safety/control_plane.yml` and `k3s_safety/cluster.yml`.
- Safety invariant: stale or extra etcd membership fails before any K3s configuration file is copied.

- [ ] **Step 1: Install an etcdctl version compatible with the pinned K3s release**

Append these tasks to `ansible/roles/baseline/tasks/main.yml`:

```yaml
- name: Set etcdctl architecture
  ansible.builtin.set_fact:
    etcdctl_arch: >-
      {{ {'x86_64': 'amd64', 'aarch64': 'arm64'}[ansible_facts['architecture']] }}
  when: node_role in ["cp_only", "cp_worker"]

- name: Download the pinned etcd release archive
  ansible.builtin.get_url:
    url: >-
      https://github.com/etcd-io/etcd/releases/download/v3.6.12/etcd-v3.6.12-linux-{{ etcdctl_arch }}.tar.gz
    dest: "/var/cache/etcd-v3.6.12-linux-{{ etcdctl_arch }}.tar.gz"
    owner: root
    group: root
    mode: "0644"
    checksum: >-
      sha256:https://github.com/etcd-io/etcd/releases/download/v3.6.12/SHA256SUMS
  when: node_role in ["cp_only", "cp_worker"]

- name: Install etcdctl
  ansible.builtin.unarchive:
    src: "/var/cache/etcd-v3.6.12-linux-{{ etcdctl_arch }}.tar.gz"
    dest: /usr/local/bin
    remote_src: true
    include:
      - "etcd-v3.6.12-linux-{{ etcdctl_arch }}/etcdctl"
    extra_opts:
      - --strip-components=1
    owner: root
    group: root
    mode: "0755"
  when: node_role in ["cp_only", "cp_worker"]
```

The client version matches the upstream etcd `3.6.12` carried by K3s `v1.36.2+k3s1`; the K3s-specific server suffix does not require a K3s-specific client build.

- [ ] **Step 2: Converge the non-disruptive baseline one node at a time**

Run:

```bash
rtk proxy just ansible-check baseline
rtk proxy just ansible-converge baseline
```

Expected:

- Existing packages and unattended-upgrade files remain unchanged.
- `etcdctl` is installed only on control-plane nodes.
- K3s is not restarted.
- No server is rebooted.

- [ ] **Step 3: Add safety-role defaults**

Create `ansible/roles/k3s_safety/defaults/main.yml`:

```yaml
---
k3s_safety_expected_control_planes: "{{ groups['control_planes'] | length }}"
k3s_safety_cilium_wait: 2m
k3s_safety_etcd_endpoints: "https://127.0.0.1:2379"
k3s_safety_etcd_cacert: /var/lib/rancher/k3s/server/tls/etcd/server-ca.crt
k3s_safety_etcd_cert: /var/lib/rancher/k3s/server/tls/etcd/client.crt
k3s_safety_etcd_key: /var/lib/rancher/k3s/server/tls/etcd/client.key
```

- [ ] **Step 4: Add per-control-plane API and etcd checks**

Create `ansible/roles/k3s_safety/tasks/control_plane.yml`:

```yaml
---
- name: Require an odd control-plane count of at least three
  ansible.builtin.assert:
    that:
      - k3s_safety_expected_control_planes | int >= 3
      - k3s_safety_expected_control_planes | int % 2 == 1
    fail_msg: >-
      Refusing node mutation: inventory has
      {{ k3s_safety_expected_control_planes }} control-plane nodes; expected
      an odd count of at least three.

- name: Require the local K3s service to be active
  ansible.builtin.command:
    cmd: systemctl is-active k3s
  changed_when: false
  check_mode: false

- name: Require the local API readiness endpoint
  ansible.builtin.command:
    cmd: k3s kubectl get --raw=/readyz?verbose
  register: k3s_safety_readyz
  changed_when: false
  check_mode: false
  failed_when: >-
    k3s_safety_readyz.rc != 0 or
    'readyz check passed' not in k3s_safety_readyz.stdout

- name: Read embedded-etcd membership
  ansible.builtin.command:
    argv:
      - /usr/local/bin/etcdctl
      - "--endpoints={{ k3s_safety_etcd_endpoints }}"
      - "--cacert={{ k3s_safety_etcd_cacert }}"
      - "--cert={{ k3s_safety_etcd_cert }}"
      - "--key={{ k3s_safety_etcd_key }}"
      - member
      - list
      - --write-out=json
  register: k3s_safety_etcd_members
  changed_when: false
  check_mode: false
  no_log: false

- name: Require exact embedded-etcd membership
  ansible.builtin.assert:
    that:
      - >-
        (k3s_safety_etcd_members.stdout | from_json).members | length
        == k3s_safety_expected_control_planes | int
    fail_msg: >-
      Refusing node mutation: embedded-etcd membership does not equal the
      declared control-plane count. Remove stale membership through an
      explicit membership runbook before retrying.

- name: Require every embedded-etcd endpoint healthy
  ansible.builtin.command:
    argv:
      - /usr/local/bin/etcdctl
      - "--endpoints={{ k3s_safety_etcd_endpoints }}"
      - "--cacert={{ k3s_safety_etcd_cacert }}"
      - "--cert={{ k3s_safety_etcd_cert }}"
      - "--key={{ k3s_safety_etcd_key }}"
      - endpoint
      - health
      - --cluster
  changed_when: false
  check_mode: false
```

- [ ] **Step 5: Add operator-side Node and Cilium checks**

Create `ansible/roles/k3s_safety/tasks/cluster.yml`:

```yaml
---
- name: Read every declared control-plane Node
  kubernetes.core.k8s_info:
    api_version: v1
    kind: Node
    name: "{{ item }}"
  loop: "{{ groups['control_planes'] }}"
  register: k3s_safety_node_results

- name: Require every declared control-plane Node Ready
  ansible.builtin.assert:
    that:
      - item.resources | length == 1
      - >-
        item.resources[0].status.conditions
        | selectattr('type', 'equalto', 'Ready')
        | map(attribute='status')
        | first
        | default('False') == 'True'
    fail_msg: >-
      Refusing node mutation: {{ item.item }} is missing or not Ready.
  loop: "{{ k3s_safety_node_results.results }}"
  loop_control:
    label: "{{ item.item }}"

- name: Require Cilium healthy
  ansible.builtin.command:
    argv:
      - cilium
      - status
      - --wait
      - "--wait-duration={{ k3s_safety_cilium_wait }}"
  changed_when: false
  check_mode: false
```

- [ ] **Step 6: Verify the role syntax and lint profile**

Run:

```bash
rtk proxy uv run ansible-playbook \
  -i ansible/inventory/hcloud.yml \
  --syntax-check \
  ansible/playbooks/k3s-config.yml
rtk proxy uv run ansible-lint \
  ansible/roles/k3s_safety \
  ansible/roles/baseline \
  ansible/playbooks/baseline.yml
```

Expected: both commands exit zero.

- [ ] **Step 7: Commit the reusable safety probes**

```bash
rtk git add ansible/roles/baseline/tasks/main.yml \
  ansible/roles/k3s_safety
rtk git commit -m "feat: add fail-closed k3s control-plane safety probes"
```

---

### Task 4: Make the K3s Configuration Rollout Fail Closed

**Files:**

- Modify: `ansible/playbooks/k3s-config.yml`
- Modify: `cmd/opsctl/verify_kubelet_config.go`
- Modify: `internal/nodecfg/kubelet.go`
- Modify: `internal/nodecfg/kubelet_test.go`
- Modify: `Justfile`
- Modify: `lefthook.yml`

**Interfaces:**

- Consumes: `k3s_safety/cluster.yml` and `k3s_safety/control_plane.yml` from Task 3.
- Consumes: role-aware `DeclaredKubeletArgs(dir, role)`.
- Produces commands: `just node-config-validate`, `just node-config-preflight`, `just node-config-check`, and `just node-config-apply`.
- Safety invariant: a failed preflight touches no node; a failed node or rollback touches no subsequent node.

- [ ] **Step 1: Write the failing role-selection tests**

Add to `internal/nodecfg/kubelet_test.go`:

```go
func TestDeclaredKubeletArgsSelectsApplicableRoleLayers(t *testing.T) {
	dir := t.TempDir()
	all := filepath.Join(dir, "all/etc/rancher/k3s/config.yaml.d/all.yaml")
	cp := filepath.Join(dir, "control-plane/etc/rancher/k3s/config.yaml.d/cp.yaml")
	require.NoError(t, os.MkdirAll(filepath.Dir(all), 0o755))
	require.NoError(t, os.MkdirAll(filepath.Dir(cp), 0o755))
	require.NoError(t, os.WriteFile(all, []byte(
		"kubelet-arg+:\n  - \"resolv-conf=/etc/rancher/k3s/resolv.conf\"\n",
	), 0o644))
	require.NoError(t, os.WriteFile(cp, []byte(
		"kubelet-arg+:\n  - \"serialize-image-pulls=false\"\n",
	), 0o644))

	worker, err := DeclaredKubeletArgs(dir, "worker")
	require.NoError(t, err)
	assert.Equal(t, []string{
		"resolv-conf=/etc/rancher/k3s/resolv.conf",
	}, worker)

	controlPlane, err := DeclaredKubeletArgs(dir, "cp_worker")
	require.NoError(t, err)
	assert.Equal(t, []string{
		"resolv-conf=/etc/rancher/k3s/resolv.conf",
		"serialize-image-pulls=false",
	}, controlPlane)
}
```

Change the existing `TestDeclaredKubeletArgs` call to:

```go
args, err := DeclaredKubeletArgs(dir, "worker")
```

- [ ] **Step 2: Run the focused test and prove it fails**

Run:

```bash
rtk go test ./internal/nodecfg -run TestDeclaredKubeletArgsSelectsApplicableRoleLayers -count=1
```

Expected: compilation fails because `DeclaredKubeletArgs` does not yet accept a role.

- [ ] **Step 3: Make declared kubelet arguments role-aware**

Change the signature in `internal/nodecfg/kubelet.go`:

```go
func DeclaredKubeletArgs(dir, role string) ([]string, error)
```

Before reading a discovered config file, add:

```go
rel, err := filepath.Rel(dir, path)
if err != nil {
	return err
}
layer := strings.Split(rel, string(filepath.Separator))[0]
if layer != "all" &&
	!(layer == "control-plane" && (role == "cp_only" || role == "cp_worker")) {
	return nil
}
```

This keeps file ordering deterministic and excludes control-plane-only values from workers.

- [ ] **Step 4: Pass the inventory role to the live verifier**

Add a required role flag to `verifyKubeletConfigCmd` in `cmd/opsctl/verify_kubelet_config.go`:

```go
Role string `required:"" enum:"cp_only,cp_worker,worker" help:"Inventory role of the target node."`
```

Change the call to:

```go
declared, err := nodecfg.DeclaredKubeletArgs(c.Dir, c.Role)
```

Run:

```bash
rtk go test ./internal/nodecfg ./cmd/opsctl
```

Expected: all tests pass.

- [ ] **Step 5: Add an explicit preflight play before mutation**

At the top of `ansible/playbooks/k3s-config.yml`, add:

```yaml
---
- name: Refuse node configuration when cluster health is uncertain
  hosts: localhost
  gather_facts: false
  any_errors_fatal: true
  tasks:
    - name: Verify Kubernetes and Cilium health
      ansible.builtin.include_role:
        name: k3s_safety
        tasks_from: cluster

- name: Refuse node configuration when any control plane is unhealthy
  hosts: control_planes
  gather_facts: false
  serial: 1
  any_errors_fatal: true
  order: sorted
  tasks:
    - name: Verify local API and embedded-etcd health
      ansible.builtin.include_role:
        name: k3s_safety
        tasks_from: control_plane
```

In the existing convergence play, add:

```yaml
  any_errors_fatal: true
```

- [ ] **Step 6: Make each changed node pass full postflight**

Change the kubelet verification command to:

```yaml
        - name: Verify kubelet runtime config matches declared state
          ansible.builtin.command:
            argv:
              - go
              - run
              - ./cmd/opsctl
              - verify-kubelet-config
              - "{{ kubernetes_node_name }}"
              - "--role={{ node_role }}"
            chdir: "{{ playbook_dir }}/../.."
```

After the existing port checks, add:

```yaml
        - name: Verify changed control plane locally
          ansible.builtin.include_role:
            name: k3s_safety
            tasks_from: control_plane
          when:
            - k3s_config_changed
            - is_control_plane
            - not ansible_check_mode

        - name: Verify cluster health after the changed node
          ansible.builtin.include_role:
            name: k3s_safety
            tasks_from: cluster
            apply:
              delegate_to: localhost
          when:
            - k3s_config_changed
            - not ansible_check_mode
```

After rollback restarts K3s, run `k3s_safety/control_plane.yml` for a control-plane node and `k3s_safety/cluster.yml` from localhost before the final explicit failure. Do not run the new-config kubelet comparison after rollback because the host intentionally contains the previous config.

- [ ] **Step 7: Fix the existing lint failures while touching the rollback block**

Replace the archive-integrity shell task with:

```yaml
        - name: Check rollback archive integrity
          ansible.builtin.command:
            argv:
              - tar
              - tzf
              - /tmp/k3s-config-rollback.tar.gz
          changed_when: false
```

Fold the final failure message below 160 characters per YAML line:

```yaml
        - name: Abort because the config change was rolled back
          ansible.builtin.fail:
            msg: >-
              {{ kubernetes_node_name }}: the new config failed its restart or
              verification gate. The previous config was restored and the node
              recovered. Fix nodes/ before retrying.
```

- [ ] **Step 8: Add four unambiguous operator commands**

Add to `Justfile`:

```just
# Offline and non-mutating: schema, syntax, and lint checks.
node-config-validate:
    just verify-node-config
    uv run ansible-lint \
        ansible/playbooks/baseline.yml \
        ansible/playbooks/k3s-config.yml \
        ansible/roles/baseline \
        ansible/roles/k3s_safety
    uv run ansible-playbook -i localhost, \
        --syntax-check ansible/playbooks/k3s-config.yml

# Read-only: refuses success unless every CP, etcd member, API, Node, and Cilium is healthy.
node-config-preflight:
    just _ansible-playbook "k3s-config" "--tags preflight"

# Preview file changes. Check mode cannot prove runtime acceptance.
node-config-check:
    just _ansible-playbook "k3s-config" "--check --diff"

# Production convergence: preflight, one changed node, postflight, stop on first failure.
node-config-apply:
    just node-config-validate
    just _ansible-playbook "k3s-config"
```

Tag both preflight plays and their tasks with `preflight`; tag the convergence play with `converge`. The preflight recipe must never reach a copy, restart, restore, drain, or package-install task.

- [ ] **Step 9: Run node validation automatically before commit**

Add to `lefthook.yml` under `pre-commit.commands`:

```yaml
    ansible-lint:
      run: >-
        uv run ansible-lint
        ansible/playbooks/baseline.yml
        ansible/playbooks/k3s-config.yml
        ansible/roles/baseline
        ansible/roles/k3s_safety
      glob:
        - "ansible/**/*.yaml"
        - "ansible/**/*.yml"

    node-config-schema:
      run: go run ./cmd/opsctl verify-node-config
      glob:
        - "nodes/**/*.yaml"
        - "nodes/**/*.yml"
        - "infra/locals.tf"
        - "internal/nodecfg/*.go"
        - "cmd/opsctl/verify_node_config.go"
```

- [ ] **Step 10: Verify syntax, lint, focused tests, and the read-only preflight**

Run:

```bash
rtk go test ./internal/nodecfg ./cmd/opsctl
rtk proxy just node-config-validate
rtk proxy just node-config-preflight
```

Expected:

- Go tests pass.
- Syntax check passes.
- Ansible lint reports zero violations.
- Preflight reports every declared control plane Ready.
- etcd member count equals the control-plane inventory count.
- every etcd endpoint is healthy.
- Cilium reports healthy.
- Runner records the read-only run.

- [ ] **Step 11: Prove the new rollout path is an idempotent no-op**

Run:

```bash
rtk proxy just node-config-check
rtk proxy just node-config-apply
```

Expected:

- Preflight passes.
- The K3s configuration copy tasks report unchanged.
- No K3s handler runs.
- No node restarts.
- Final recap reports `changed=0` for every node.

Do not inject a production failure during this migration. The existing 2026-07-25 game-day result already proves the rollback block; schedule another game day only after a separate explicit decision.

- [ ] **Step 12: Commit the fail-closed rollout**

```bash
rtk git add ansible/playbooks/k3s-config.yml Justfile lefthook.yml \
  cmd/opsctl/verify_kubelet_config.go \
  internal/nodecfg/kubelet.go internal/nodecfg/kubelet_test.go
rtk git commit -m "feat: gate node config on api etcd and cilium health"
```

---

### Task 5: Remove Generic Go Plumbing and Update the Operating Contract

**Files:**

- Delete: `ansible/inventory/tofu_inventory`
- Delete: `cmd/opsctl/ansible_inventory.go`
- Delete: `internal/inventory/inventory.go`
- Delete: `internal/inventory/inventory_test.go`
- Delete: `internal/inventory/load.go`
- Modify: `cmd/opsctl/main.go`
- Modify: `docs/runbook.md`
- Modify: `docs/specs/2026-05-10-node-configuration-management-adr.md`
- Modify: `CLAUDE.md`
- Modify: `go.mod`
- Modify: `go.sum`

**Interfaces:**

- Consumes: the proven standard inventory and Runner path from Tasks 1–4.
- Produces: no `opsctl` or Go dependency for inventory discovery.
- Retains: narrow node-schema and live-kubelet verification because they catch failures that upstream YAML validation does not.

- [ ] **Step 1: Delete the generic inventory implementation**

Delete:

```text
ansible/inventory/tofu_inventory
cmd/opsctl/ansible_inventory.go
internal/inventory/inventory.go
internal/inventory/inventory_test.go
internal/inventory/load.go
```

Remove this field from `cli` in `cmd/opsctl/main.go`:

```go
AnsibleInventory ansibleInventoryCmd `cmd:"" name:"ansible-inventory" help:"Ansible dynamic inventory built from tofu outputs."`
```

- [ ] **Step 2: Remove dependencies made unused by the deletion**

Run:

```bash
rtk go mod tidy
rtk go test ./...
rtk go build ./cmd/opsctl
```

Expected: all Go tests and the opsctl build pass.

- [ ] **Step 3: Update the runbook around one safe path**

Replace the inventory, check, and convergence sections of `docs/runbook.md` with:

````markdown
### Node configuration

Inventory comes from the read-only `hetzner.hcloud.hcloud` plugin. It selects
servers labeled `cluster=hetzner-k3s`; it never creates, rebuilds, resizes, or
deletes a server.

Run local schema, syntax, and lint validation:

```bash
just node-config-validate
```

Run the read-only production gate:

```bash
just node-config-preflight
```

Preview declared file changes:

```bash
just node-config-check
```

Apply after reviewing the diff:

```bash
just node-config-apply
```

The apply command:

1. validates K3s and kubelet flag names against the pinned binaries;
2. requires every control plane, embedded-etcd endpoint, API, Node, and Cilium
   healthy;
3. changes one node;
4. requires complete postflight before another node is eligible;
5. restores the failed node and stops when verification fails.

Runner evidence is stored under `.artifacts/ansible/<run-id>/`. Inspect
`status`, `rc`, `stdout`, and `job_events/` for the exact failing host and task.

This workflow cannot invoke OpenTofu or a Hetzner lifecycle action. Node
creation, replacement, reset, and deletion remain separate manual runbooks.
````

- [ ] **Step 4: Record the refined architecture decision**

Append to `docs/specs/2026-05-10-node-configuration-management-adr.md`:

```markdown
## 2026-07-26 Refinement: upstream execution, local safety policy

The Ubuntu and K3s decision remains unchanged. Existing Hetzner servers are
long-lived infrastructure identities and are not rebuilt by configuration
convergence.

Generic machinery is delegated upstream:

- `hetzner.hcloud.hcloud` discovers existing servers;
- Ansible Runner executes playbooks and records structured artifacts;
- `kubernetes.core` reads Kubernetes state;
- `etcdctl` is the embedded-etcd membership and endpoint-health oracle;
- the Cilium CLI is the CNI-health oracle.

Repository-specific automation is limited to policy that upstream tools cannot
infer: this cluster requires all three control planes healthy before mutation,
exact etcd membership, one changed node at a time, and API/Cilium/etcd
postflight before continuation.

Disposable local VM testing and disposable Hetzner testing are optional.
Neither is a prerequisite for convergence, and no test workflow may rebuild a
production server.
```

- [ ] **Step 5: Update the hard repository rule**

In `CLAUDE.md`, replace references to `just ansible-converge k3s-config` and direct `_ansible-playbook` use with:

```text
just node-config-validate
just node-config-preflight
just node-config-check
just node-config-apply
```

State explicitly:

```text
Node configuration never runs tofu or a Hetzner lifecycle action. A failed
node stops the run before another node is touched. Runner artifacts under
.artifacts/ansible identify the failing host and task.
```

- [ ] **Step 6: Run the complete non-destructive acceptance suite**

Run:

```bash
rtk git status --short
rtk go test ./...
rtk go build ./cmd/opsctl
rtk proxy uv run ansible-lint \
  ansible/playbooks/baseline.yml \
  ansible/playbooks/k3s-config.yml \
  ansible/roles/baseline \
  ansible/roles/k3s_safety
rtk proxy uv run ansible-playbook \
  -i ansible/inventory/hcloud.yml \
  --syntax-check ansible/playbooks/site.yml
rtk proxy uv run ansible-playbook \
  -i ansible/inventory/hcloud.yml \
  --syntax-check ansible/playbooks/k3s-config.yml
rtk proxy just ansible-inventory
rtk proxy just node-config-validate
rtk proxy just node-config-preflight
rtk proxy just node-config-check
```

Expected:

- Go tests and build pass.
- Ansible lint and both syntax checks pass.
- Inventory contains exactly the existing servers.
- Preflight passes without changes.
- Check mode shows only the intentionally planned file diff.
- No K3s service restarts.
- OpenTofu is not invoked.

- [ ] **Step 7: Commit the deletion and operating contract**

```bash
rtk git add -A
rtk git commit -m "refactor: remove custom node inventory plumbing"
```

---

## Out of Scope

These are separate decisions, not missing work in this plan:

- Adopting `k3s-io/k3s-ansible` for future first-boot installation or membership changes.
- Moving K3s installation out of `infra/scripts/init.sh.tpl`.
- Automated node replacement, rotation, resize, reset, uninstall, or etcd-member removal.
- Packer images, transactional Linux, MicroOS, NixOS, or Talos.
- AWX, Semaphore, or another persistent controller.
- ARA; Runner artifacts provide the initial failure record without another service.
- Molecule with local VMs; add it only when a stable local virtualization backend exists.
- Molecule with Hetzner; keep it manual and opt-in because capacity is not guaranteed.

## Delivery Checkpoints

1. After Task 1, inventory no longer requires new Go logic, but the old path remains as rollback.
2. After Task 2, every Ansible run has durable artifacts and a hard one-fork default.
3. After Task 3, all required safety oracles exist without restarting K3s.
4. After Task 4, production node configuration is fail closed and idempotent.
5. After Task 5, generic Go inventory plumbing is deleted and the new contract is documented.

Estimated execution time:

- Tasks 1–2: 3–4 hours.
- Tasks 3–4: 5–8 hours, including careful read-only and no-op production verification.
- Task 5: 1–2 hours.
- Total: 1–2 focused working days.
