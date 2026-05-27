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

# Seal the Cloudflare Tunnel token as a SealedSecret.
# Run AFTER `just apply` creates the tunnel. Requires cluster access.
# After running, add sealed-tunnel-token.yaml to the kustomization resources list and commit.
seal-cloudflared-token:
    #!/usr/bin/env bash
    set -euo pipefail
    token=$(cd "{{ infra }}" && sops exec-env "{{ infra / "secrets.yaml" }}" "tofu output -raw tunnel_token")
    out="{{ k8s / "base/infra/cloudflared/resources/sealed-tunnel-token.yaml" }}"
    printf '%s' "$token" | \
        kubectl create secret generic cloudflared-tunnel-token \
            --namespace cloudflared \
            --from-file=token=/dev/stdin \
            --dry-run=client -o yaml | \
        kubeseal \
            --controller-namespace kube-system \
            --controller-name sealed-secrets-controller \
            --format yaml \
            > "$out"
    echo "Sealed token written to $out"
    echo "Next: add 'sealed-tunnel-token.yaml' to kubernetes/base/infra/cloudflared/resources/kustomization.yaml, then commit both."

# Seal R2 credentials for k3s etcd snapshot S3 upload.
# Run AFTER Task 2 (R2 buckets created, credentials in secrets.yaml).
# Requires cluster access (kubeseal reads the sealed-secrets controller pubkey).
seal-etcd-s3:
    #!/usr/bin/env bash
    set -euo pipefail
    out="{{ k8s / "components/etcd-snapshot-health/resources/sealedsecret-etcd-s3.yaml" }}"
    sops exec-env "{{ infra / "secrets.yaml" }}" \
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
    printf 'Sealed to %s - add sealedsecret-etcd-s3.yaml to resources/kustomization.yaml and commit.\n' "$out"

# Seal R2 credentials for Velero BackupStorageLocation.
# Run AFTER Task 2. Requires cluster access.
seal-velero-s3:
    #!/usr/bin/env bash
    set -euo pipefail
    out="{{ k8s / "components/velero-restore-drill/resources/sealedsecret-velero-r2.yaml" }}"
    creds=$'[default]\naws_access_key_id=${R2_VELERO_ACCESS_KEY}\naws_secret_access_key=${R2_VELERO_SECRET_KEY}'
    sops exec-env "{{ infra / "secrets.yaml" }}" \
        'kubectl create secret generic velero-r2-credentials \
            --namespace velero \
            --from-literal=cloud="'"$creds"'" \
            --dry-run=client -o yaml | \
        kubeseal \
            --controller-namespace kube-system \
            --controller-name sealed-secrets-controller \
            --format yaml' \
        > "$out"
    printf 'Sealed to %s - add sealedsecret-velero-r2.yaml to velero-restore-drill/resources/kustomization.yaml and commit.\n' "$out"

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

# Rotate the LUKS passphrase: generate, seal, commit, push, sync.
# The passphrase is never printed — recoverable via SOPS → sealed-secrets chain.
# Run `just ops-recreate-encrypted-pvcs` afterwards to reformat the PVCs.
rotate-luks-passphrase:
    #!/usr/bin/env bash
    set -euo pipefail
    PASSPHRASE=$(openssl rand -base64 32)
    kubectl create secret generic hcloud-luks-key \
        --namespace kube-system \
        --from-literal=encryption-passphrase="$PASSPHRASE" \
        --dry-run=client -o yaml | \
    kubeseal --cert kubernetes/sealed-secrets-cert.pem --format yaml \
        > kubernetes/components/hcloud-luks-key/resources/sealed-luks-key.yaml
    unset PASSPHRASE
    git add kubernetes/components/hcloud-luks-key/resources/sealed-luks-key.yaml
    git commit -m "security: rotate hcloud-luks-key passphrase"
    git push
    argocd app sync hcloud-luks-key --core
    echo ""
    echo "Passphrase rotated and live in cluster."
    echo "Run 'just ops-recreate-encrypted-pvcs' to reformat PVCs with the new passphrase."

# Recreate encrypted PVCs for Grafana, Alertmanager, Tempo (data loss is OK).
# Run after just rotate-luks-passphrase, or any time PVCs need to be rebuilt.
ops-recreate-encrypted-pvcs *args:
    just _ansible-playbook "ops/recreate-encrypted-pvcs" "{{ args }}"

# Migrate Prometheus TSDB data to the encrypted StorageClass.
# Interactive — has two human checkpoints. Read the playbook before running.
# Do NOT pass --check: command tasks are no-ops in check mode.
ops-migrate-prometheus:
    just _ansible-playbook "ops/migrate-prometheus-encrypted"

# Verify the VXLAN+WireGuard MTU stack is correctly configured.
#
# Cilium's MTU param is the physical device MTU (auto-detect = enp7s0 = 1450).
# Expected stack: enp7s0=1450 → cilium_wg0=1370 (-80 WireGuard overhead).
# Pod interface MTU stays at 1450; path MTU enforcement is done via PMTUD
# (packetization-layer-pmtud-mode=always) for UDP/ICMP and eBPF MSS clamping
# for TCP. Packets at the VXLAN ceiling (payload ≤ 1292b = 1320b IP) must pass.
#
# Run after bootstrap or any Cilium config change. Exits non-zero on failure.
verify-mtu:
    #!/usr/bin/env bash
    set -euo pipefail

    # enp7s0 (Hetzner private NIC) - WireGuard IPv6 overhead (80 bytes)
    EXPECTED_WG_MTU=1370
    # Cilium sets pod interfaces to the native device MTU (enp7s0 = 1450)
    EXPECTED_POD_MTU=1450
    # 1292 + 28 (IP+ICMP headers) = 1320 bytes = max IP packet through VXLAN/WireGuard
    CEILING_PAYLOAD=1292
    # Comfortable margin below ceiling
    PASS_PAYLOAD=1280

    kubectl delete pod mtu-verify-a mtu-verify-b \
      --ignore-not-found=true --wait=true >/dev/null 2>&1 || true

    NODES=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'))
    if [[ ${#NODES[@]} -lt 2 ]]; then
      echo "ERROR: need at least 2 nodes for a cross-node test" >&2; exit 1
    fi
    NODE_A="${NODES[0]}"
    NODE_B="${NODES[1]}"

    cleanup() {
      kubectl delete pod mtu-verify-a mtu-verify-b \
        --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
      kill "$PF_PID" 2>/dev/null || true
      wait "$PF_PID" 2>/dev/null || true
    }
    trap cleanup EXIT
    PF_PID=""

    echo "▸ Deploying test pods — $NODE_A and $NODE_B"
    kubectl run mtu-verify-a --image=busybox:1.36 --restart=Never \
      --overrides="{\"spec\":{\"nodeName\":\"$NODE_A\"}}" -- sleep 300 >/dev/null
    kubectl run mtu-verify-b --image=busybox:1.36 --restart=Never \
      --overrides="{\"spec\":{\"nodeName\":\"$NODE_B\"}}" -- sleep 300 >/dev/null
    kubectl wait pod mtu-verify-a mtu-verify-b --for=condition=Ready --timeout=90s >/dev/null

    POD_B_IP=$(kubectl get pod mtu-verify-b -o jsonpath='{.status.podIP}')
    PASS=true

    # ── Check 1: pod interface MTU (should equal native device MTU) ────────────
    echo "▸ Checking pod interface MTU"
    ACTUAL_MTU=$(kubectl exec mtu-verify-a -- ip link show eth0 2>/dev/null | grep -oP 'mtu \K\d+')
    if [[ "$ACTUAL_MTU" -eq "$EXPECTED_POD_MTU" ]]; then
      echo "  pod eth0 MTU = $ACTUAL_MTU ✓"
    else
      echo "  FAIL: pod eth0 MTU = $ACTUAL_MTU, expected $EXPECTED_POD_MTU ✗"
      PASS=false
    fi

    # ── Check 2: cross-node connectivity at comfortable margin ─────────────────
    echo "▸ Cross-node ping: payload=${PASS_PAYLOAD}b (packet=$((PASS_PAYLOAD+28))b)"
    LOSS=$(kubectl exec mtu-verify-a -- ping -s "$PASS_PAYLOAD" -c 3 -W 2 "$POD_B_IP" 2>&1 \
           | grep -oP '\d+(?=% packet loss)' | head -1 || echo "100")
    if [[ "$LOSS" -eq 0 ]]; then
      echo "  ${PASS_PAYLOAD}b payload → ${LOSS}% loss ✓"
    else
      echo "  FAIL: ${PASS_PAYLOAD}b payload → ${LOSS}% loss — cross-node path broken ✗"
      PASS=false
    fi

    # ── Check 3: cross-node at VXLAN/WireGuard path ceiling ───────────────────
    echo "▸ Cross-node ping: payload=${CEILING_PAYLOAD}b (packet=$((CEILING_PAYLOAD+28))b, path ceiling)"
    LOSS=$(kubectl exec mtu-verify-a -- ping -s "$CEILING_PAYLOAD" -c 3 -W 2 "$POD_B_IP" 2>&1 \
           | grep -oP '\d+(?=% packet loss)' | head -1 || echo "100")
    if [[ "$LOSS" -eq 0 ]]; then
      echo "  ${CEILING_PAYLOAD}b payload → ${LOSS}% loss ✓"
    else
      echo "  FAIL: ${CEILING_PAYLOAD}b payload → ${LOSS}% loss — effective path MTU below 1320 ✗"
      PASS=false
    fi

    # ── Check 4: WireGuard interface MTU on each node ──────────────────────────
    echo "▸ Checking cilium_wg0 MTU on each node (expected: enp7s0 1450 - WG 80 = ${EXPECTED_WG_MTU})"
    for POD in $(kubectl get pod -n kube-system -l k8s-app=cilium -o name | cut -d/ -f2); do
      NODE=$(kubectl get pod -n kube-system "$POD" -o jsonpath='{.spec.nodeName}')
      WG_MTU=$(kubectl exec -n kube-system "$POD" -c cilium-agent -- \
               ip link show cilium_wg0 2>/dev/null | grep -oP 'mtu \K\d+' || echo "unknown")
      if [[ "$WG_MTU" -eq "$EXPECTED_WG_MTU" ]]; then
        echo "  $NODE cilium_wg0 = $WG_MTU ✓"
      else
        echo "  FAIL: $NODE cilium_wg0 = $WG_MTU, expected $EXPECTED_WG_MTU ✗"
        PASS=false
      fi
    done

    # ── Check 5: PMTUD enabled (safety net for oversized UDP/ICMP) ─────────────
    echo "▸ Checking PMTUD is enabled in Cilium configmap"
    PMTUD=$(kubectl get configmap -n kube-system cilium-config \
            -o jsonpath='{.data.enable-pmtu-discovery}' 2>/dev/null || echo "false")
    PMTUD_MODE=$(kubectl get configmap -n kube-system cilium-config \
                 -o jsonpath='{.data.packetization-layer-pmtud-mode}' 2>/dev/null || echo "blackhole")
    if [[ "$PMTUD" == "true" && "$PMTUD_MODE" == "always" ]]; then
      echo "  enable-pmtu-discovery=true, mode=always ✓"
    else
      echo "  FAIL: PMTUD not active (enabled=$PMTUD, mode=$PMTUD_MODE) ✗"
      PASS=false
    fi

    # ── Check 6: cloudflared QUIC MTU (egress path sanity check) ──────────────
    # quic_client_mtu reflects the pod egress path MTU minus QUIC/tunnel overhead.
    # Expected: ~1344 when pod MTU=1450. Dropping below 1300 means pod MTU
    # is being clamped too aggressively somewhere in the stack.
    MIN_QUIC_MTU=1300
    CF_POD=$(kubectl get pod -n cloudflared -l app=cloudflared -o name 2>/dev/null \
             | head -1 | cut -d/ -f2)
    if [[ -n "$CF_POD" ]]; then
      echo "▸ Checking cloudflared quic_client_mtu (pod: $CF_POD)"
      kubectl port-forward -n cloudflared "$CF_POD" 12001:2000 >/dev/null 2>&1 &
      PF_PID=$!
      sleep 2
      QUIC_MTUS=$(curl -s --max-time 3 http://localhost:12001/metrics 2>/dev/null \
                  | grep 'quic_client_mtu{' | awk '{print $2}' || true)
      if [[ -z "$QUIC_MTUS" ]]; then
        echo "  WARN: could not read quic_client_mtu from cloudflared metrics"
      else
        QUIC_MIN=$(echo "$QUIC_MTUS" | sort -n | head -1 | cut -d. -f1)
        if [[ "$QUIC_MIN" -ge "$MIN_QUIC_MTU" ]]; then
          echo "  quic_client_mtu min=$QUIC_MIN (threshold >=${MIN_QUIC_MTU}) ✓"
        else
          echo "  FAIL: quic_client_mtu min=$QUIC_MIN < ${MIN_QUIC_MTU} — pod egress MTU clamped too low ✗"
          PASS=false
        fi
      fi
    else
      echo "▸ cloudflared not found — skipping QUIC MTU check"
    fi

    echo ""
    if [[ "$PASS" == "true" ]]; then
      echo "✓ MTU verification passed"
    else
      echo "✗ MTU verification FAILED — see above" >&2
      exit 1
    fi

@_sops-apply file:
    sops --decrypt "{{ file }}" | kubectl apply -f -
