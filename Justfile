infra := justfile_dir() / "infra"
k8s := justfile_dir() / "kubernetes"
export KUBECONFIG := infra / "kubeconfig.yaml"

# API endpoint Cilium points at from inside the cluster. Today: private IP of
# cp-1 (matches infra/locals.tf control_plane_ip). For HA: set this to the
# private IP of a Hetzner LB sitting in front of all control planes.
export K8S_API_ENDPOINT := "10.0.0.2"

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
    # This is a one-time operation that should be done after ArgoCD is installed and
    # before creating any applications that need to access the private repo.
    sops --decrypt "{{ k8s / "bootstrap/secrets/argocd-repo-ssh.sops.yaml" }}" | kubectl apply -f -

@argocd-root-bootstrap:
    # This is a one-time operation that should be done after ArgoCD is installed and
    # before creating any applications that need to access the private repo.
    kubectl apply -f "{{ k8s / "root-application.yaml" }}"

# This is a one-time operation that should be done after the cluster is up and before applying any sealed secrets.
restore-sealed-secrets-key:
    sops --decrypt "{{ k8s / "bootstrap/secrets/sealed-secrets-master-key.sops.yaml" }}" | kubectl apply -f -
