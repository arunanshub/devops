infra := justfile_dir() / "infra"

@plan:
    cd "{{ infra }}" && sops exec-env "{{ infra / "secrets.yaml" }}" "tofu plan"
