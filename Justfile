infra := justfile_dir() / "infra"
k8s := justfile_dir() / "kubernetes"
export KUBECONFIG := infra / "kubeconfig.yaml"
ansible_dir := justfile_dir() / "ansible"

# Internal API endpoint used by Cilium and other in-cluster components.
# Points at the API server LB private IP, not a specific node.
export K8S_API_ENDPOINT := "10.0.0.100"

@plan:
    cd "{{ infra }}" && sops exec-env "{{ infra / "secrets.yaml" }}" "tofu plan"

apply:
    cd "{{ infra }}" && sops exec-env "{{ infra / "secrets.yaml" }}" "tofu apply"

destroy:
    cd "{{ infra }}" && sops exec-env "{{ infra / "secrets.yaml" }}" "tofu destroy"

@launch-argocd-ui:
    echo "Launching ArgoCD UI at http://localhost:8080"
    kubectl port-forward svc/argocd-server -n argocd 8080:443

@launch-grafana:
    echo "Launching Grafana UI at http://localhost:3000"
    kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80

@launch-hubble-ui:
    echo "Launching Hubble UI at http://localhost:12000"
    kubectl port-forward svc/hubble-ui -n kube-system 12000:80

# Apply the hcloud Secret to kube-system. Required before argocd-bootstrap
# because hccm (installed by helmfile) reads this secret on startup. The Secret
# carries the `sealedsecrets.bitnami.com/managed: "true"` annotation in the
# SOPS source, so the SealedSecret in kubernetes/infra/ can adopt it later
# without conflict. Idempotent.
@hcloud-secret-bootstrap:
    sops --decrypt "{{ k8s / "bootstrap/secrets/hcloud-ccm-secret.sops.yaml" }}" | kubectl apply -f -

argocd-bootstrap: hcloud-secret-bootstrap
    cd "{{ k8s / "bootstrap/" }}" && helmfile deps && sops exec-env "{{ k8s / "bootstrap/secrets/helmfile.secrets.yaml" }}" "helmfile apply"

# Bootstrap ArgoCD with the SSH key for accessing the private repo.
@argocd-ssh-bootstrap:
    sops --decrypt "{{ k8s / "bootstrap/secrets/argocd-repo-ssh.sops.yaml" }}" | kubectl apply -f -

@argocd-root-bootstrap:
    kubectl apply -f "{{ k8s / "root-application.yaml" }}"

@ansible-inventory:
    cd "{{ justfile_dir() }}" && sops exec-env "{{ infra / "secrets.yaml" }}" \
        "ANSIBLE_CONFIG='{{ ansible_dir / "ansible.cfg" }}' '{{ ansible_dir / "inventory/tofu_inventory.py" }}' --list"

@ansible-baseline-check:
    cd "{{ justfile_dir() }}" && sops exec-env "{{ infra / "secrets.yaml" }}" \
        "ANSIBLE_CONFIG='{{ ansible_dir / "ansible.cfg" }}' ansible-playbook -i '{{ ansible_dir / "inventory/tofu_inventory.py" }}' '{{ ansible_dir / "playbooks/baseline.yml" }}' --check --diff"

ansible-baseline:
    cd "{{ justfile_dir() }}" && sops exec-env "{{ infra / "secrets.yaml" }}" \
        "ANSIBLE_CONFIG='{{ ansible_dir / "ansible.cfg" }}' ansible-playbook -i '{{ ansible_dir / "inventory/tofu_inventory.py" }}' '{{ ansible_dir / "playbooks/baseline.yml" }}'"

# Restore the sealed-secrets master key from the offline backup.
# Must run BEFORE ArgoCD syncs any SealedSecret resources on a rebuilt cluster.
# After applying, restart the controller so it picks up the restored key.
restore-sealed-secrets-key:
    sops --decrypt "{{ k8s / "bootstrap/secrets/sealed-secrets-master-key.sops.yaml" }}" | kubectl apply -f -
    kubectl rollout restart deployment sealed-secrets-controller -n kube-system
