infra := justfile_dir() / "infra"
k8s := justfile_dir() / "kubernetes"
kubeconfig := env_var_or_default("KUBECONFIG", infra / "kubeconfig.yaml")
export KUBECONFIG := kubeconfig
ansible_dir := justfile_dir() / "ansible"
ansible_inventory := ansible_dir / "inventory/hcloud.yml"
ansible_playbooks := ansible_dir / "playbooks"
ansible_runner := ansible_dir / "runner"
ansible_artifacts := justfile_dir() / ".artifacts/ansible"
ansible_env := "LC_ALL=C.UTF-8 LANG=C.UTF-8 KUBECONFIG='" + kubeconfig + "'"

# Internal API endpoint used by Cilium and other in-cluster components.
# Points at the API server LB private IP, not a specific node.
export K8S_API_ENDPOINT := "10.0.0.100"

@plan:
    just _tofu plan

apply:
    just _tofu apply

destroy:
    just _tofu destroy

@_tofu command:
    cd "{{ infra }}" && sops exec-env "{{ infra / "secrets.yaml" }}" "tofu {{ command }}"

@launch-argocd-ui:
    just _port-forward "ArgoCD UI" "http://localhost:8080" "svc/argocd-server -n argocd 8080:443"

@launch-grafana:
    just _port-forward "Grafana UI" "http://localhost:3000" "svc/kube-prometheus-stack-grafana -n monitoring 3000:80"

@launch-hubble-ui:
    just _port-forward "Hubble UI" "http://localhost:12000" "svc/hubble-ui -n kube-system 12000:80"

@_port-forward name url target:
    echo "Launching {{ name }} at {{ url }}"
    kubectl port-forward {{ target }}

# Applies the hcloud Secret before helmfile so hccm can start.
@hcloud-secret-bootstrap:
    just _sops-apply "{{ k8s / "bootstrap/secrets/hcloud-ccm-secret.sops.yaml" }}"

argocd-bootstrap: hcloud-secret-bootstrap
    cd "{{ k8s / "bootstrap/" }}" && helmfile deps && sops exec-env "{{ k8s / "bootstrap/secrets/helmfile.secrets.yaml" }}" "helmfile apply"

# Bootstrap ArgoCD with the SSH key for accessing the private repo.
@argocd-ssh-bootstrap:
    just _sops-apply "{{ k8s / "bootstrap/secrets/argocd-repo-ssh.sops.yaml" }}"

@argocd-root-bootstrap:
    kubectl apply -f "{{ k8s / "root-application.yaml" }}"

ansible-inventory:
    sops exec-env "{{ infra / "secrets.yaml" }}" "{{ ansible_env }} uv run ansible-inventory -i '{{ ansible_inventory }}' --graph --vars"

node-preflight:
    just _ansible-playbook k3s-preflight

ansible-check playbook="site":
    just _ansible-playbook "{{ playbook }}" "--check --diff"

# Rolling: every node-mutating play sets serial: 1 + max_fail_percentage: 0
# and gates each node on cluster health before the next.
ansible-converge playbook="site":
    just _ansible-playbook "{{ playbook }}"

# Runner evidence goes to .artifacts/ansible. --omit-env-files keeps the
# sops-injected environment out of those artifacts.
_ansible-playbook playbook args="":
    sops exec-env "{{ infra / "secrets.yaml" }}" "{{ ansible_env }} uv run ansible-runner run '{{ ansible_runner }}' --project-dir '{{ justfile_dir() }}' --inventory '{{ ansible_inventory }}' --artifact-dir '{{ ansible_artifacts }}' --rotate-artifacts 20 --omit-env-files --forks 1 --playbook 'ansible/playbooks/{{ playbook }}.yml' --cmdline='{{ args }}'"

# Install Python deps (uv) and Ansible collections. Run once after cloning or
# after pyproject.toml / ansible/requirements.yml changes.
ansible-setup:
    uv sync --dev
    uv run ansible-galaxy collection install -r ansible/requirements.yml -p ansible/collections/ --force

# Restore the sealed-secrets master key from the offline backup.
# Must run BEFORE ArgoCD syncs any SealedSecret resources on a rebuilt cluster.
# After applying, restart the controller so it picks up the restored key.
restore-sealed-secrets-key:
    just _sops-apply "{{ k8s / "bootstrap/secrets/sealed-secrets-master-key.sops.yaml" }}"
    kubectl rollout restart deployment sealed-secrets-controller -n kube-system

# Offline sealing only: --cert uses the key held in the bootstrap backup,
# so a rebuilt cluster can decrypt the result. Sealing against the live
# controller uses its newest key, which the backup does not hold.
sealing_cert := k8s / "sealed-secrets-cert.pem"

# Seal a SOPS-encrypted Secret: foo.sops.yaml -> foo.sealedsecret.yaml (same dir).
seal file:
    sops -d "{{ file }}" | kubeseal --cert "{{ sealing_cert }}" -o yaml > "{{ replace(file, ".sops.yaml", ".sealedsecret.yaml") }}"

# Seal the Cloudflare Tunnel token from tofu state.
seal-tunnel-token:
    just _tofu "output -raw tunnel_token" | kubectl create secret generic cloudflared-tunnel-token -n cloudflared --from-file=token=/dev/stdin --dry-run=client -o yaml | kubeseal --cert "{{ sealing_cert }}" -o yaml > "{{ k8s / "components/cloudflared/resources/tunnel-token.sealedsecret.yaml" }}"

# Seal an app's Cloudflare cache-purge token from tofu state.
# Usage: just seal-cache-purge arunanshu-dev cache_purge_token
# just seal-cache-purge libby-hbd-2026 libby_hbd_2026_cache_purge_token
seal-cache-purge app output:
    kubectl create secret generic cloudflare-cache-purge -n "{{ app }}" --from-literal=zone_id="$(awk -F'"' '/cloudflare_zone_id/{print $2}' "{{ infra / "terraform.tfvars" }}")" --from-literal=api_token="$(just _tofu 'output -raw {{ output }}')" --dry-run=client -o yaml | kubeseal --cert "{{ sealing_cert }}" -o yaml > "{{ k8s / "base/apps" / app / "resources/cf-cache-purge.sealedsecret.yaml" }}"

# Show current Velero backup and restore status.
@velero-status:
    @echo "=== Backups ==="
    kubectl exec -n velero deploy/velero -- /velero backup get
    @echo ""
    @echo "=== Restores ==="
    kubectl exec -n velero deploy/velero -- /velero restore get
    @echo ""
    @echo "=== Backup Storage Location ==="
    kubectl exec -n velero deploy/velero -- /velero backup-location get

# Create a Velero restore from a named backup into a target namespace.
# IMPORTANT: disable ArgoCD auto-sync on NAMESPACE before running; re-enable after verifying.
# Usage: just velero-restore <backup-name> <namespace>
velero-restore backup namespace:
    #!/usr/bin/env bash
    set -euo pipefail
    printf '>> Disable ArgoCD auto-sync first:\n'
    printf '   kubectl patch application {{ namespace }} -n argocd --type merge -p '"'"'{"spec":{"syncPolicy":{"automated":null}}}'"'"'\n'
    printf '\n'
    read -r -p "Confirm auto-sync is disabled for '{{ namespace }}' [y/N]: " confirm
    [[ "$confirm" == "y" ]] || { printf 'Aborted.\n'; exit 1; }
    kubectl exec -n velero deploy/velero -- /velero restore create \
        --from-backup "{{ backup }}" \
        --include-namespaces "{{ namespace }}" \
        --wait
    printf '\n'
    printf '>> Restore complete. Verify state, then re-enable auto-sync:\n'
    printf '   kubectl patch application {{ namespace }} -n argocd --type merge -p '"'"'{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'"'"'\n'

# Print the manual etcd restore procedure. Credentials must be passed directly via CLI.
@etcd-restore:
    @echo "=== Manual etcd restore procedure ==="
    @echo ""
    @echo "1. Download the target snapshot from R2:"
    @echo "   AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret> \\"
    @echo "   aws s3 cp s3://arunanshu-etcd-snapshots/prod/<snapshot-name> /tmp/snapshot.db \\"
    @echo "   --endpoint-url https://<account_id>.r2.cloudflarestorage.com --region auto"
    @echo ""
    @echo "2. Stop k3s on ALL nodes:"
    @echo "   ansible all -i ansible/inventory/hcloud.yml -m service -a 'name=k3s state=stopped' --become"
    @echo ""
    @echo "3. Reset etcd on ONE control-plane node (e.g. cp-0):"
    @echo "   k3s server --cluster-reset --cluster-reset-restore-path=/tmp/snapshot.db"
    @echo "   (This node will exit after reset — that is expected)"
    @echo ""
    @echo "4. Start k3s on the RESET node first, wait for it to become Ready:"
    @echo "   systemctl start k3s && kubectl get nodes"
    @echo ""
    @echo "5. Start k3s on remaining CP nodes (one at a time):"
    @echo "   systemctl start k3s"
    @echo ""
    @echo "Note: the S3 config Secret is unavailable during restore."
    @echo "Pass credentials directly via --etcd-s3-* flags if downloading live."

# ── Encrypted PV operations ───────────────────────────────────────────────────

# Rotate the LUKS passphrase. It is never printed; it stays recoverable
# through the sealed-secrets backup. Commit, sync, then run
# `just ops-recreate-encrypted-pvcs` to reformat the PVCs.
rotate-luks-passphrase:
    openssl rand -base64 32 | tr -d '\n' | kubectl create secret generic hcloud-luks-key -n kube-system --from-file=encryption-passphrase=/dev/stdin --dry-run=client -o yaml | kubeseal --cert "{{ sealing_cert }}" -o yaml > "{{ k8s / "components/hcloud-luks-key/resources/luks-key.sealedsecret.yaml" }}"

# Recreate encrypted PVCs for Grafana, Alertmanager, Tempo (data loss is OK).
# Run after just rotate-luks-passphrase, or any time PVCs need to be rebuilt.
ops-recreate-encrypted-pvcs *args:
    just _ansible-playbook "ops/recreate-encrypted-pvcs" "{{ args }}"

# Verify the VXLAN+WireGuard MTU stack is correctly configured.
# Implemented in Go: cmd/opsctl (verify-mtu subcommand). Expected values and
# their derivation are documented on the flags (`just opsctl verify-mtu --help`)
# and in docs/incidents/cilium-mtu-overlay-networking.md.
# Run after bootstrap or any Cilium config change. Exits non-zero on failure.
verify-mtu *flags:
    go run ./cmd/opsctl verify-mtu {{ flags }}

# Capture bounded WireGuard handshake and tx_dropped evidence from exactly one node.
# Dynamic debug is restored in an Ansible always block. No service is restarted.
# The playbook validates the node and the 60-1800 s duration.
diagnose-wireguard node="hetzner-k3s-cp-2" duration="900":
    just _ansible-playbook ops/cilium-wireguard-diagnostics "--limit {{ node }},localhost --extra-vars wireguard_capture_duration={{ duration }}"

# Run the operations toolkit from source (see `just opsctl --help`).
opsctl *args:
    go run ./cmd/opsctl {{ args }}

# Verify the helmfile→ArgoCD adoption invariant (also runs in CI).
# The password hash is rendered but excluded from comparison, so any
# non-empty value satisfies requiredEnv here.
verify-adoption:
    ARGOCD_ADMIN_PASSWORD_HASH=placeholder go run ./cmd/opsctl verify-adoption

# Validate nodes/ config against the pinned k3s/kubelet flag schemas (also in CI).
verify-node-config:
    go run ./cmd/opsctl verify-node-config

# Build the operations toolkit to bin/opsctl.
build:
    go build -ldflags="-s -w" -trimpath -o bin/opsctl ./cmd/opsctl

@_sops-apply file:
    sops --decrypt "{{ file }}" | kubectl apply -f -
