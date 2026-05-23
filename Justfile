infra := justfile_dir() / "infra"
k8s := justfile_dir() / "kubernetes"
export KUBECONFIG := infra / "kubeconfig.yaml"
ansible_dir := justfile_dir() / "ansible"
ansible_inventory := ansible_dir / "inventory/tofu_inventory"
ansible_playbooks := ansible_dir / "playbooks"
ansible_env := "LC_ALL=C.UTF-8 LANG=C.UTF-8 ANSIBLE_CONFIG='" + ansible_dir / "ansible.cfg" + "'"

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
        "{{ ansible_env }} ansible-playbook -i '{{ ansible_inventory }}' '{{ ansible_playbooks }}/{{ playbook }}.yml' {{ args }}"

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

@_sops-apply file:
    sops --decrypt "{{ file }}" | kubectl apply -f -
