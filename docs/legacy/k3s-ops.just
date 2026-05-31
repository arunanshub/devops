# Legacy k3s + ansible operational recipes — preserved for reference.
#
# These were the day-two ops primitives for the k3s cluster. Kept here as a
# record of what the Talos migration replaced and why.
#
# NOT executable in the current repo — ansible inventory and k3s binaries are
# gone. Do not re-add to the root Justfile without a full k3s cluster present.
#
# Replacement mapping:
#   ansible-converge (eviction)     → talosctl machineconfig patch @patches/eviction.yaml
#   ansible-converge (baseline)     → talosctl apply-config (idempotent declarative config)
#   ops-recreate-encrypted-pvcs     → kubectl delete pvc + ArgoCD sync (PV Retain keeps volume)
#   ops-migrate-prometheus          → manual drain + PV Retain + pre-create PV/PVC
#   etcd-restore                    → talosctl etcd recover (see talos-ops.just)
#   seal-etcd-s3 (k3s type)        → seal-etcd-s3 in root Justfile (Opaque type, same keys)

# ── Variables (k3s era) ───────────────────────────────────────────────────────

ansible_dir     := justfile_dir() / "../../ansible"
ansible_inventory := ansible_dir / "inventory/tofu_inventory"
ansible_playbooks := ansible_dir / "playbooks"
ansible_env     := "LC_ALL=C.UTF-8 LANG=C.UTF-8 KUBECONFIG='" + justfile_dir() / "../../infra/kubeconfig.yaml" + "'"

# ── Ansible ───────────────────────────────────────────────────────────────────

@ansible-inventory:
    cd "{{ justfile_dir() / "../.." }}" && sops exec-env "{{ justfile_dir() / "../../infra/secrets.yaml" }}" \
        "{{ ansible_env }} '{{ ansible_inventory }}' --list"

@ansible-check playbook="site":
    just _ansible-playbook "{{ playbook }}" "--check --diff"

ansible-converge playbook="site":
    just _ansible-playbook "{{ playbook }}"

@_ansible-playbook playbook args="":
    test -f "{{ ansible_playbooks }}/{{ playbook }}.yml"
    cd "{{ justfile_dir() / "../.." }}" && sops exec-env "{{ justfile_dir() / "../../infra/secrets.yaml" }}" \
        "{{ ansible_env }} uv run ansible-playbook -i '{{ ansible_inventory }}' '{{ ansible_playbooks }}/{{ playbook }}.yml' {{ args }}"

ansible-setup:
    uv sync --dev
    uv run ansible-galaxy collection install -r ansible/requirements.yml -p ansible/collections/ --force

ansible-apply playbook="site":
    just ansible-converge "{{ playbook }}"

@ansible-baseline-check:
    just ansible-check baseline

ansible-baseline:
    just ansible-converge baseline

# ── k3s PV/encrypted volume ops ──────────────────────────────────────────────

# Recreate encrypted PVCs for Grafana, Alertmanager, Tempo (data loss is OK).
# Run after just rotate-luks-passphrase, or any time PVCs need to be rebuilt.
# REPLACED BY: kubectl delete pvc + ArgoCD sync (reclaim policy = Retain, volume survives)
ops-recreate-encrypted-pvcs *args:
    just _ansible-playbook "ops/recreate-encrypted-pvcs" "{{ args }}"

# Migrate Prometheus TSDB data to the encrypted StorageClass.
# Interactive — has two human checkpoints. Read the playbook before running.
# REPLACED BY: manual scale-down + PV Retain + pre-create PV/PVC pattern
ops-migrate-prometheus:
    just _ansible-playbook "ops/migrate-prometheus-encrypted"

# ── k3s etcd restore ─────────────────────────────────────────────────────────

# Manual k3s etcd restore procedure (SSH + systemctl based).
# REPLACED BY: talosctl etcd recover (see docs/legacy/talos-ops-notes.md)
@etcd-restore:
    @echo "=== k3s manual etcd restore procedure ==="
    @echo ""
    @echo "1. Download the target snapshot from R2:"
    @echo "   AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret> \\"
    @echo "   aws s3 cp s3://arunanshu-etcd-snapshots/prod/<snapshot-name> /tmp/snapshot.db \\"
    @echo "   --endpoint-url https://<account_id>.r2.cloudflarestorage.com --region auto"
    @echo ""
    @echo "2. Stop k3s on ALL nodes:"
    @echo "   ansible all -i ansible/inventory/tofu_inventory -m service -a 'name=k3s state=stopped' --become"
    @echo ""
    @echo "3. Reset etcd on ONE control-plane node (e.g. cp-1):"
    @echo "   k3s server --cluster-reset --cluster-reset-restore-path=/tmp/snapshot.db"
    @echo "   (This node exits after reset — expected)"
    @echo ""
    @echo "4. Start k3s on the RESET node first, wait for Ready:"
    @echo "   systemctl start k3s && kubectl get nodes"
    @echo ""
    @echo "5. Start k3s on remaining CP nodes one at a time:"
    @echo "   systemctl start k3s"
    @echo ""
    @echo "Note: S3 config Secret unavailable during restore."
    @echo "Pass credentials directly via --etcd-s3-* flags if downloading live."

# ── k3s-specific sealing ─────────────────────────────────────────────────────

# Seal R2 credentials for k3s etcd snapshot S3 upload.
# Used the k3s-specific Secret type etcd.k3s.cattle.io/s3-config-secret so k3s
# would auto-configure S3 uploads. Talos version uses Opaque type (same keys,
# same CronJob) — see seal-etcd-s3 in root Justfile.
seal-etcd-s3-k3s:
    #!/usr/bin/env bash
    set -euo pipefail
    out="{{ justfile_dir() / "../../kubernetes/components/etcd-snapshot-health/resources/sealedsecret-etcd-s3.yaml" }}"
    sops exec-env "{{ justfile_dir() / "../../infra/secrets.yaml" }}" \
        'kubectl create secret generic k3s-etcd-snapshot-s3-config \
            --namespace kube-system \
            --type etcd.k3s.cattle.io/s3-config-secret \
            --from-literal=etcd-s3-endpoint="${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
            --from-literal=etcd-s3-access-key="${R2_ETCD_ACCESS_KEY}" \
            --from-literal=etcd-s3-secret-key="${R2_ETCD_SECRET_KEY}" \
            --from-literal=etcd-s3-bucket=arunanshu-etcd-snapshots \
            --from-literal=etcd-s3-region=auto \
            --from-literal=etcd-s3-bucket-lookup-type=path \
            --from-literal=etcd-s3-folder=prod \
            --from-literal=etcd-s3-insecure=false \
            --from-literal=etcd-s3-timeout=5m \
            --dry-run=client -o yaml | \
        kubeseal \
            --controller-namespace kube-system \
            --controller-name sealed-secrets-controller \
            --format yaml' \
        > "$out"
    printf 'Sealed to %s\n' "$out"
