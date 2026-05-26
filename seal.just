# ── Credential sealing recipes ───────────────────────────────────────────────
# All recipes generate a SealedSecret YAML and write it to the repo.
# Run `just apply` first so Terraform outputs are available.
# Requires an active cluster connection (kubeseal fetches the controller pubkey).

# Seal the Cloudflare Tunnel token as a SealedSecret.
# Run AFTER `just apply` creates the tunnel. Requires cluster access.
# After running, add sealed-tunnel-token.yaml to the kustomization resources list and commit.
seal-cloudflared-token:
    #!/usr/bin/env bash
    set -euo pipefail
    token=$(cd "{{ infra }}" && sops exec-env "{{ infra / "secrets.yaml" }}" "tofu output -raw tunnel_token")
    out="{{ k8s / "components/cloudflared/resources/sealed-tunnel-token.yaml" }}"
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
    echo "Next: add 'sealed-tunnel-token.yaml' to kubernetes/components/cloudflared/resources/kustomization.yaml, then commit both."

# Seal R2 credentials for k3s etcd snapshot S3 upload.
# Run AFTER R2 buckets are created and credentials are in secrets.yaml.
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
# Run AFTER R2 buckets are created and credentials are in secrets.yaml.
# Requires cluster access.
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

# Seal the Tailscale operator OAuth credentials as a SealedSecret.
# Run AFTER `just apply` so the tailscale_oauth_client Terraform resource exists.
# After running, add operator-oauth.sealedsecret.yaml to
# kubernetes/base/infra/tailscale-operator/resources/kustomization.yaml and commit.
seal-tailscale-oauth:
    #!/usr/bin/env bash
    set -euo pipefail
    client_id=$(cd "{{ infra }}" && sops exec-env "{{ infra / "secrets.yaml" }}" "tofu output -raw tailscale_oauth_client_id")
    client_secret=$(cd "{{ infra }}" && sops exec-env "{{ infra / "secrets.yaml" }}" "tofu output -raw tailscale_oauth_client_secret")
    out="{{ k8s / "base/infra/tailscale-operator/resources/operator-oauth.sealedsecret.yaml" }}"
    kubectl create secret generic operator-oauth \
        --namespace tailscale \
        --from-literal=client_id="$client_id" \
        --from-literal=client_secret="$client_secret" \
        --dry-run=client -o yaml | \
    kubeseal \
        --controller-namespace kube-system \
        --controller-name sealed-secrets-controller \
        --format yaml \
        > "$out"
    echo "Sealed to $out"
    echo "Next: add 'operator-oauth.sealedsecret.yaml' to kubernetes/base/infra/tailscale-operator/resources/kustomization.yaml, then commit both."

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
    kubeseal --cert "{{ k8s }}/sealed-secrets-cert.pem" --format yaml \
        > "{{ k8s }}/components/hcloud-luks-key/resources/sealed-luks-key.yaml"
    unset PASSPHRASE
    git add "{{ k8s }}/components/hcloud-luks-key/resources/sealed-luks-key.yaml"
    git commit -m "security: rotate hcloud-luks-key passphrase"
    git push
    argocd app sync hcloud-luks-key --core
    echo ""
    echo "Passphrase rotated and live in cluster."
    echo "Run 'just ops-recreate-encrypted-pvcs' to reformat PVCs with the new passphrase."
