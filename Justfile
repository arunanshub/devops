infra := justfile_dir() / "infra"
k8s := justfile_dir() / "kubernetes"
export KUBECONFIG := infra / "kubeconfig.yaml"
ansible_dir := justfile_dir() / "ansible"
ansible_inventory := ansible_dir / "inventory/tofu_inventory"
ansible_playbooks := ansible_dir / "playbooks"
ansible_env := "LC_ALL=C.UTF-8 LANG=C.UTF-8 KUBECONFIG='" + infra / "kubeconfig.yaml" + "'"

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

# Apply the hcloud Secret to kube-system. Required before argocd-bootstrap
# because hccm (installed by helmfile) reads this secret on startup. The Secret
# carries the `sealedsecrets.bitnami.com/managed: "true"` annotation in the
# SOPS source, so the SealedSecret in kubernetes/infra/ can adopt it later
# without conflict. Idempotent.
@hcloud-secret-bootstrap:
    just _sops-apply "{{ k8s / "bootstrap/secrets/hcloud-ccm-secret.sops.yaml" }}"

argocd-bootstrap: hcloud-secret-bootstrap
    cd "{{ k8s / "bootstrap/" }}" && helmfile deps && sops exec-env "{{ k8s / "bootstrap/secrets/helmfile.secrets.yaml" }}" "helmfile apply"

# Bootstrap ArgoCD with the SSH key for accessing the private repo.
@argocd-ssh-bootstrap:
    just _sops-apply "{{ k8s / "bootstrap/secrets/argocd-repo-ssh.sops.yaml" }}"

@argocd-root-bootstrap:
    kubectl apply -f "{{ k8s / "root-application.yaml" }}"

@ansible-inventory:
    cd "{{ justfile_dir() }}" && sops exec-env "{{ infra / "secrets.yaml" }}" \
        "{{ ansible_env }} '{{ ansible_inventory }}' --list"

@ansible-check playbook="site":
    just _ansible-playbook "{{ playbook }}" "--check --diff"

ansible-converge playbook="site":
    just _ansible-playbook "{{ playbook }}"

@_ansible-playbook playbook args="":
    test -f "{{ ansible_playbooks }}/{{ playbook }}.yml"
    cd "{{ justfile_dir() }}" && sops exec-env "{{ infra / "secrets.yaml" }}" \
        "{{ ansible_env }} uv run ansible-playbook -i '{{ ansible_inventory }}' '{{ ansible_playbooks }}/{{ playbook }}.yml' {{ args }}"

# Install Python deps (uv) and Ansible collections. Run once after cloning or
# after pyproject.toml / ansible/requirements.yml changes.
ansible-setup:
    uv sync --dev
    uv run ansible-galaxy collection install -r ansible/requirements.yml -p ansible/collections/ --force

ansible-apply playbook="site":
    just ansible-converge "{{ playbook }}"

@ansible-baseline-check:
    just ansible-check baseline

ansible-baseline:
    just ansible-converge baseline

# Restore the sealed-secrets master key from the offline backup.
# Must run BEFORE ArgoCD syncs any SealedSecret resources on a rebuilt cluster.
# After applying, restart the controller so it picks up the restored key.
restore-sealed-secrets-key:
    just _sops-apply "{{ k8s / "bootstrap/secrets/sealed-secrets-master-key.sops.yaml" }}"
    kubectl rollout restart deployment sealed-secrets-controller -n kube-system

import 'seal.just'

# Show current Velero backup and restore status.
@velero-status:
    @echo "=== Backups ==="
    kubectl exec -n velero deploy/velero -- velero backup get
    @echo ""
    @echo "=== Restores ==="
    kubectl exec -n velero deploy/velero -- velero restore get
    @echo ""
    @echo "=== Backup Storage Location ==="
    kubectl exec -n velero deploy/velero -- velero backup-location get

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
    kubectl exec -n velero deploy/velero -- velero restore create \
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
    @echo "   ansible all -i ansible/inventory/tofu_inventory -m service -a 'name=k3s state=stopped' --become"
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

# Recreate encrypted PVCs for Grafana, Alertmanager, Tempo (data loss is OK).
# Run after just rotate-luks-passphrase, or any time PVCs need to be rebuilt.
ops-recreate-encrypted-pvcs *args:
    just _ansible-playbook "ops/recreate-encrypted-pvcs" "{{ args }}"

# Migrate Prometheus TSDB data to the encrypted StorageClass.
# Interactive — has two human checkpoints. Read the playbook before running.
# Do NOT pass --check: command tasks are no-ops in check mode.
ops-migrate-prometheus:
    just _ansible-playbook "ops/migrate-prometheus-encrypted"

@_sops-apply file:
    sops --decrypt "{{ file }}" | kubectl apply -f -
