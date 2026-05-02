infra := justfile_dir() / "infra"
k8s := justfile_dir() / "kubernetes"
export KUBECONFIG := infra / "kubeconfig.yaml"

@plan:
    cd "{{ infra }}" && sops exec-env "{{ infra / "secrets.yaml" }}" "tofu plan"

apply:
    cd "{{ infra }}" && sops exec-env "{{ infra / "secrets.yaml" }}" "tofu apply"

destroy:
    cd "{{ infra }}" && sops exec-env "{{ infra / "secrets.yaml" }}" "tofu destroy"

@launch-argocd-ui:
    echo "Launching ArgoCD UI at http://localhost:8080"
    kubectl port-forward svc/argocd-server -n argocd 8080:443

# Bootstrap ArgoCD with the SSH key for accessing the private repo.
@argocd-ssh-bootstrap:
    # This is a one-time operation that should be done after ArgoCD is installed and
    # before creating any applications that need to access the private repo.
    sops --decrypt "{{ k8s / "bootstrap/secrets/argocd-repo-ssh.sops.yaml" }}" | kubectl apply -f -

@argocd-root-bootstrap:
    # This is a one-time operation that should be done after ArgoCD is installed and
    # before creating any applications that need to access the private repo.
    kubectl apply -f "{{ k8s / "bootstrap/root-application.yaml" }}"
