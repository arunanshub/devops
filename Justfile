infra := justfile_dir() / "infra"
k8s := justfile_dir() / "kubernetes"
export KUBECONFIG := infra / "kubeconfig.yaml"

# Internal API endpoint used by Cilium and other in-cluster components.
export K8S_API_ENDPOINT := "10.0.0.100"

# Node IPs — used by talosctl recipes.
talos_nodes := "10.0.0.2,10.0.0.3,10.0.0.4"
talos_dir := justfile_dir() / "talos"
talos_configs := talos_dir / "clusterconfig"

# ── Infrastructure ────────────────────────────────────────────────────────────

@plan:
    just _tofu plan

apply:
    just _tofu apply

destroy:
    just _tofu destroy

@_tofu command:
    cd "{{ infra }}" && sops exec-env "{{ infra / "secrets.yaml" }}" "tofu {{ command }}"

# ── Talos bootstrap (cutover day) ─────────────────────────────────────────────

# Apply machineconfigs to all nodes while in maintenance mode (first boot from ISO).
# Nodes must be reachable but not yet bootstrapped. --insecure: no mTLS cert yet.
talos-apply-configs:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ talos_dir }}" && talhelper genconfig
    for node in 10.0.0.2 10.0.0.3 10.0.0.4; do
        suffix=$(echo "$node" | awk -F. '{print $4 - 1}')
        cfg="{{ talos_configs }}/hetzner-talos-cp-${suffix}.yaml"
        echo "▸ Applying config to $node ($cfg)"
        talosctl apply-config --insecure --nodes "$node" --file "$cfg"
    done

# Bootstrap etcd on the first control-plane node. Run once after apply-configs.
@talos-bootstrap:
    talosctl bootstrap --nodes 10.0.0.2
    talosctl health --nodes {{ talos_nodes }}

# Fetch kubeconfig from the cluster and write to infra/kubeconfig.yaml.
@talos-kubeconfig:
    talosctl kubeconfig --nodes 10.0.0.2 "{{ infra / "kubeconfig.yaml" }}"

# ── Talos day-two ops ─────────────────────────────────────────────────────────

# Rolling Talos OS upgrade across all nodes. Updates the OS + kernel.
# Usage: just talos-upgrade v1.13.2
talos-upgrade version:
    #!/usr/bin/env bash
    set -euo pipefail
    IMAGE="ghcr.io/siderolabs/installer:{{ version }}"
    echo "▸ Upgrading Talos to {{ version }} (image: $IMAGE)"
    for node in 10.0.0.2 10.0.0.3 10.0.0.4; do
        echo "▸ Upgrading $node"
        talosctl upgrade --nodes "$node" --image "$IMAGE" --wait
        talosctl health --nodes "$node"
    done
    echo "✓ All nodes upgraded to {{ version }}"

# Upgrade Kubernetes version. Run after talos-upgrade if bumping k8s.
# Usage: just talos-upgrade-k8s 1.34.0
@talos-upgrade-k8s version:
    talosctl upgrade-k8s --to {{ version }} --nodes 10.0.0.2

# Apply a machineconfig patch to all nodes (no reboot for most changes).
# Usage: just talos-patch @docs/plans/talos-spike/patches/eviction.yaml
@talos-patch patch:
    talosctl patch machineconfig --nodes {{ talos_nodes }} --patch "{{ patch }}"

# ── Cluster bootstrap (ArgoCD) ────────────────────────────────────────────────

# Apply the hcloud Secret before helmfile bootstrap — hccm reads it on startup.
@hcloud-secret-bootstrap:
    just _sops-apply "{{ k8s / "bootstrap/secrets/hcloud-ccm-secret.sops.yaml" }}"

argocd-bootstrap: hcloud-secret-bootstrap
    cd "{{ k8s / "bootstrap/" }}" && helmfile deps && sops exec-env "{{ k8s / "bootstrap/secrets/helmfile.secrets.yaml" }}" "helmfile apply"

@argocd-ssh-bootstrap:
    just _sops-apply "{{ k8s / "bootstrap/secrets/argocd-repo-ssh.sops.yaml" }}"

@argocd-root-bootstrap:
    kubectl apply -f "{{ k8s / "root-application.yaml" }}"

# Restore the sealed-secrets master key. Must run BEFORE ArgoCD syncs any
# SealedSecret resources. Key is SOPS-encrypted in-repo; age key required.
restore-sealed-secrets-key:
    just _sops-apply "{{ k8s / "bootstrap/secrets/sealed-secrets-master-key.sops.yaml" }}"
    kubectl rollout restart deployment sealed-secrets-controller -n kube-system

# ── etcd ─────────────────────────────────────────────────────────────────────

# Take a manual etcd snapshot and upload to R2.
# Talos replacement for k3s's automatic --etcd-snapshot-schedule-cron.
# TODO: wrap in a CronJob so this runs automatically (see etcd-snapshot-health).
talos-etcd-snapshot:
    #!/usr/bin/env bash
    set -euo pipefail
    SNAPSHOT="/tmp/etcd-snapshot-$(date +%Y%m%d-%H%M%S).db"
    echo "▸ Taking etcd snapshot → $SNAPSHOT"
    talosctl etcd snapshot --nodes 10.0.0.2 "$SNAPSHOT"
    echo "▸ Uploading to R2 (arunanshu-etcd-snapshots/prod/)"
    sops exec-env "{{ infra / "secrets.yaml" }}" \
        "AWS_ENDPOINT_URL_S3=https://\${R2_ACCOUNT_ID}.r2.cloudflarestorage.com \
         AWS_ACCESS_KEY_ID=\${R2_ETCD_ACCESS_KEY} \
         AWS_SECRET_ACCESS_KEY=\${R2_ETCD_SECRET_KEY} \
         aws s3 cp $SNAPSHOT s3://arunanshu-etcd-snapshots/prod/ --region auto"
    rm -f "$SNAPSHOT"
    echo "✓ Snapshot uploaded"

# Print the Talos etcd restore procedure.
@etcd-restore:
    @echo "=== Talos etcd restore procedure ==="
    @echo ""
    @echo "1. Download snapshot from R2:"
    @echo "   AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret> \\"
    @echo "   aws s3 cp s3://arunanshu-etcd-snapshots/prod/<snapshot> /tmp/snapshot.db \\"
    @echo "   --endpoint-url https://<account_id>.r2.cloudflarestorage.com --region auto"
    @echo ""
    @echo "2. Bootstrap cluster from snapshot (replaces normal talos-bootstrap):"
    @echo "   talosctl bootstrap --nodes 10.0.0.2 --recover-from=/tmp/snapshot.db"
    @echo ""
    @echo "3. If cluster is partially up, wipe and rebuild first:"
    @echo "   talosctl reset --nodes <node> --graceful=false --reboot"
    @echo "   (then re-apply machineconfig and bootstrap from snapshot)"
    @echo ""
    @echo "See: https://www.talos.dev/latest/advanced/disaster-recovery/"
    @echo ""
    @echo "Legacy k3s procedure: docs/legacy/k3s-ops.just :: etcd-restore"

# ── Sealing ───────────────────────────────────────────────────────────────────

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

# Seal R2 credentials for etcd snapshot health CronJob.
# Secret type is Opaque (not k3s-specific). CronJob reads keys directly.
# Legacy k3s version (type etcd.k3s.cattle.io/s3-config-secret): docs/legacy/k3s-ops.just
seal-etcd-s3:
    #!/usr/bin/env bash
    set -euo pipefail
    out="{{ k8s / "components/etcd-snapshot-health/resources/sealedsecret-etcd-s3.yaml" }}"
    sops exec-env "{{ infra / "secrets.yaml" }}" \
        'kubectl create secret generic k3s-etcd-snapshot-s3-config \
            --namespace kube-system \
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
    printf 'Sealed to %s\n' "$out"

# ── LUKS ─────────────────────────────────────────────────────────────────────

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
    echo "Volumes will unlock with new passphrase on next pod restart."

# ── Velero ────────────────────────────────────────────────────────────────────

@velero-status:
    @echo "=== Backups ==="
    kubectl exec -n velero deploy/velero -- /velero backup get
    @echo ""
    @echo "=== Restores ==="
    kubectl exec -n velero deploy/velero -- /velero restore get
    @echo ""
    @echo "=== Backup Storage Location ==="
    kubectl exec -n velero deploy/velero -- /velero backup-location get

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

# ── Observability ─────────────────────────────────────────────────────────────

@launch-argocd-ui:
    just _port-forward "ArgoCD UI" "http://localhost:8080" "svc/argocd-server -n argocd 8080:443"

@launch-grafana:
    just _port-forward "Grafana UI" "http://localhost:3000" "svc/kube-prometheus-stack-grafana -n monitoring 3000:80"

@launch-hubble-ui:
    just _port-forward "Hubble UI" "http://localhost:12000" "svc/hubble-ui -n kube-system 12000:80"

@_port-forward name url target:
    echo "Launching {{ name }} at {{ url }}"
    kubectl port-forward {{ target }}

# Verify the VXLAN+WireGuard MTU stack is correctly configured.
# Run after bootstrap or any Cilium config change.
verify-mtu:
    #!/usr/bin/env bash
    set -euo pipefail

    EXPECTED_WG_MTU=1370
    EXPECTED_POD_MTU=1450
    CEILING_PAYLOAD=1292
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

    echo "▸ Checking pod interface MTU"
    ACTUAL_MTU=$(kubectl exec mtu-verify-a -- ip link show eth0 2>/dev/null | grep -oP 'mtu \K\d+')
    if [[ "$ACTUAL_MTU" -eq "$EXPECTED_POD_MTU" ]]; then
      echo "  pod eth0 MTU = $ACTUAL_MTU ✓"
    else
      echo "  FAIL: pod eth0 MTU = $ACTUAL_MTU, expected $EXPECTED_POD_MTU ✗"
      PASS=false
    fi

    echo "▸ Cross-node ping: payload=${PASS_PAYLOAD}b (packet=$((PASS_PAYLOAD+28))b)"
    LOSS=$(kubectl exec mtu-verify-a -- ping -s "$PASS_PAYLOAD" -c 3 -W 2 "$POD_B_IP" 2>&1 \
           | grep -oP '\d+(?=% packet loss)' | head -1 || echo "100")
    if [[ "$LOSS" -eq 0 ]]; then
      echo "  ${PASS_PAYLOAD}b payload → ${LOSS}% loss ✓"
    else
      echo "  FAIL: ${PASS_PAYLOAD}b payload → ${LOSS}% loss — cross-node path broken ✗"
      PASS=false
    fi

    echo "▸ Cross-node ping: payload=${CEILING_PAYLOAD}b (packet=$((CEILING_PAYLOAD+28))b, path ceiling)"
    LOSS=$(kubectl exec mtu-verify-a -- ping -s "$CEILING_PAYLOAD" -c 3 -W 2 "$POD_B_IP" 2>&1 \
           | grep -oP '\d+(?=% packet loss)' | head -1 || echo "100")
    if [[ "$LOSS" -eq 0 ]]; then
      echo "  ${CEILING_PAYLOAD}b payload → ${LOSS}% loss ✓"
    else
      echo "  FAIL: ${CEILING_PAYLOAD}b payload → ${LOSS}% loss — effective path MTU below 1320 ✗"
      PASS=false
    fi

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

# ── Internal ──────────────────────────────────────────────────────────────────

@_sops-apply file:
    sops --decrypt "{{ file }}" | kubectl apply -f -
