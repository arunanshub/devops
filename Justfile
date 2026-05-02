infra := justfile_dir() / "infra"
k8s := justfile_dir() / "k8s"
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

@argocd-ssh-bootstrap:
    sops --decrypt "{{ k8s / "bootstrap/secrets/argocd-repo-secret.secrets.yaml" }}" | kubectl apply -f -
