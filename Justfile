infra := justfile_dir() / "infra"
bootstrap := justfile_dir() / "kubernetes/bootstrap"

@plan:
    cd "{{ infra }}" && sops exec-env "{{ infra / "secrets.yaml" }}" "tofu plan"

apply:
    cd "{{ infra }}" && sops exec-env "{{ infra / "secrets.yaml" }}" "tofu apply"

destroy:
    cd "{{ infra }}" && sops exec-env "{{ infra / "secrets.yaml" }}" "tofu destroy"

argocd-bootstrap:
    cd "{{ bootstrap }}" && sops exec-env "{{ bootstrap / "secrets.yaml" }}" "helmfile apply"

argocd-self-manage:
    kubectl apply -f kubernetes/apps/argocd/application.yaml

sealed-secrets-deploy:
    kubectl apply -f kubernetes/apps/sealed-secrets/application.yaml
