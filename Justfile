infra := justfile_dir() / "infra"

# bootstrap := justfile_dir() / "kubernetes/bootstrap"

k8s := justfile_dir() / "kubernetes"

@plan:
    cd "{{ infra }}" && sops exec-env "{{ infra / "secrets.yaml" }}" "tofu plan"

apply:
    cd "{{ infra }}" && sops exec-env "{{ infra / "secrets.yaml" }}" "tofu apply"

destroy:
    cd "{{ infra }}" && sops exec-env "{{ infra / "secrets.yaml" }}" "tofu destroy"

# ==================================== kubernetes related tasks ====================================

k8s-bootstrap: _argocd-bootstrap _argocd-self-manage _sealed-secrets-deploy _fetch-cluster-cert

# step 1. Bootstrap argocd
@_argocd-bootstrap:
    echo "{{ GREEN }}[1/5] Bootstrapping ArgoCD to the cluster...{{ WHITE }}"
    cd "{{ k8s / "bootstrap" }}" && sops exec-env "{{ k8s / "bootstrap/secrets.yaml" }}" "helmfile apply"

# step 2. make argocd self-manage itself
@_argocd-self-manage:
    echo "{{ GREEN }}[2/5] Making ArgoCD self-manage itself...{{ WHITE }}"
    kubectl apply -f "{{ k8s / "apps/argocd/application.yaml" }}"

# step 3. deploy sealed-secrets controller to the cluster
@_sealed-secrets-deploy:
    echo "{{ GREEN }}[3/5] Deploying sealed-secrets controller to the cluster...{{ WHITE }}"
    kubectl apply -f "{{ k8s / "apps/sealed-secrets/application.yaml" }}"

# step 4. encrypt secrets using kubeseal before applying them to the cluster.
@_fetch-cluster-cert:
    echo "{{ GREEN }}[4/5] Fetching cluster certificate for kubeseal...{{ WHITE }}"
    cd "{{ k8s }}" && kubeseal --fetch-cert --controller-name=sealed-secrets-controller --controller-namespace=kube-system > {{ k8s / "sealed-secrets-cert.pem" }}

# Example usage: just seal-secret mysecret.yaml > mysecret-sealed.yaml
seal-secret:
    kubeseal --controller-name=sealed-secrets-controller --controller-namespace=kube-system -o yaml < "$1"
