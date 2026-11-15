# Operator entrypoint: `just --list`. Tools and KUBECONFIG come from mise.toml.
# Shape rule (`just check-recipes`): a recipe is a few short lines; logic that
# needs more lives in the tool that owns it (helmfile, kustomize, a playbook,
# a .jq/.awk file) or, as a last resort, in opsctl.

set shell := ["bash", "-euo", "pipefail", "-c"]

cert := "kubernetes/sealed-secrets-cert.pem"
zone_id := `awk -F'"' '/cloudflare_zone_id/{print $2}' infra/terraform.tfvars`

default:
    @just --list

# ── infra ──────────────────────────────────────────────────────────────────

[group('infra')]
[working-directory('infra')]
infra-plan:
    sops exec-env secrets.yaml "tofu plan"

[group('infra')]
[working-directory('infra')]
infra-apply:
    sops exec-env secrets.yaml "tofu apply"

[confirm("Destroy every server, network and load balancer?")]
[group('infra')]
[working-directory('infra')]
infra-destroy:
    sops exec-env secrets.yaml "tofu destroy"

# ── kubernetes ─────────────────────────────────────────────────────────────

# One-shot clean-cluster bootstrap; refuses once Argo CD owns the cluster
[group('k8s')]
[working-directory('kubernetes/bootstrap')]
k8s-bootstrap:
    kubectl get --raw=/readyz >/dev/null
    # Refuse once application/root exists: Argo CD owns the cluster from then on.
    ! kubectl -n argocd get application root >/dev/null 2>&1
    helmfile deps
    sops exec-env secrets/helmfile.secrets.yaml "helmfile apply"

# Re-apply the root Application after changing its spec
[group('k8s')]
k8s-root-apply:
    kubectl apply -f kubernetes/root-application.yaml

[group('ui')]
ui-argocd:
    kubectl port-forward -n argocd svc/argocd-server 8080:443

[group('ui')]
ui-grafana:
    kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

[group('ui')]
ui-hubble:
    kubectl port-forward -n kube-system svc/hubble-ui 12000:80

# ── secrets (offline sealing against the backed-up key only) ───────────────

# Seal x.sops.yaml into x.sealedsecret.yaml next to it
[group('secrets')]
seal file:
    sops -d {{ file }} | just _seal {{ trim_end_match(file, ".sops.yaml") }}.sealedsecret.yaml

# Seal the Cloudflare Tunnel token from tofu state
[group('secrets')]
seal-tunnel-token:
    just _tofu-output tunnel_token \
      | kubectl create secret generic cloudflared-tunnel-token -n cloudflared \
          --from-file=token=/dev/stdin --dry-run=client -o yaml \
      | just _seal kubernetes/components/cloudflared/resources/tunnel-token.sealedsecret.yaml

# Seal an app's Cloudflare cache-purge token (app: arunanshu-dev | libby-hbd-2026)
[group('secrets')]
seal-cache-purge app output:
    just _tofu-output {{ output }} \
      | kubectl create secret generic cloudflare-cache-purge -n {{ app }} \
          --from-literal=zone_id={{ zone_id }} \
          --from-file=api_token=/dev/stdin --dry-run=client -o yaml \
      | just _seal kubernetes/base/apps/{{ app }}/resources/cf-cache-purge.sealedsecret.yaml

# New LUKS passphrase, never printed; commit, sync, then ops-recreate-encrypted-pvcs
[group('secrets')]
rotate-luks:
    openssl rand -base64 32 | tr -d '\n' \
      | kubectl create secret generic hcloud-luks-key -n kube-system \
          --from-file=encryption-passphrase=/dev/stdin --dry-run=client -o yaml \
      | just _seal kubernetes/components/hcloud-luks-key/resources/luks-key.sealedsecret.yaml

# Secret manifest on stdin → SealedSecret at `out`, sealed with the backed-up cert
_seal out:
    kubeseal --cert {{ cert }} -o yaml > {{ out }}

[working-directory('infra')]
_tofu-output name:
    sops exec-env secrets.yaml "tofu output -raw {{ name }}"

# ── ansible (evidence in .artifacts/ansible; node plays roll with serial: 1) ─

[group('ansible')]
ansible-setup:
    uv sync --dev
    uv run ansible-galaxy collection install --force \
      -r ansible/requirements.yml -p ansible/collections/

[group('ansible')]
ansible-inventory:
    sops exec-env infra/secrets.yaml "uv run ansible-inventory --graph --vars"

# Run one playbook (path under ansible/playbooks, no .yml) through ansible-runner
[group('ansible')]
ansible-run playbook *cmdline:
    sops exec-env infra/secrets.yaml "uv run ansible-runner run ansible/runner \
      --project-dir . --inventory ansible/inventory/hcloud.yml \
      --artifact-dir .artifacts/ansible --rotate-artifacts 20 --omit-env-files --forks 1 \
      --playbook ansible/playbooks/{{ playbook }}.yml --cmdline='{{ cmdline }}'"

[group('ansible')]
ansible-preflight: (ansible-run "k3s-preflight")

[group('ansible')]
ansible-check playbook="site": (ansible-run playbook "--check" "--diff")

[group('ansible')]
ansible-converge playbook="site": (ansible-run playbook)

# Recreate Grafana/Alertmanager/Tempo encrypted PVCs (data loss is OK)
[group('ops')]
ops-recreate-encrypted-pvcs: (ansible-run "ops/recreate-encrypted-pvcs")

# Bounded WireGuard evidence capture from one node (60-1800 s); no restarts
[group('ops')]
ops-diagnose-wireguard node="hetzner-k3s-cp-2" duration="900":
    just ansible-run ops/cilium-wireguard-diagnostics \
      --limit {{ node }},localhost --extra-vars wireguard_capture_duration={{ duration }}

# ── opsctl ─────────────────────────────────────────────────────────────────

[group('opsctl')]
build:
    go build -ldflags="-s -w" -trimpath -o bin/opsctl ./cmd/opsctl

[group('opsctl')]
opsctl *args: build
    bin/opsctl {{ args }}

# VXLAN+WireGuard MTU chain (docs/incidents/cilium-mtu-overlay-networking.md)
[group('verify')]
verify-mtu: build
    bin/opsctl verify-mtu

# helmfile release == adopting Argo CD Application (password hash excluded)
[group('verify')]
verify-adoption: build
    ARGOCD_ADMIN_PASSWORD_HASH=placeholder bin/opsctl verify-adoption

# nodes/ keys against the pinned k3s and kubelet flag schemas
[group('verify')]
verify-node-config: build
    bin/opsctl verify-node-config

# ── repo checks (lefthook and CI run these) ────────────────────────────────

catalog := "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

# Render the prod overlay and validate it against k8s + CRD schemas
[group('check')]
check-manifests:
    kustomize build kubernetes/overlays/prod \
      | kubeconform --strict --ignore-missing-schemas --summary \
          --schema-location default --schema-location '{{ catalog }}'

# No shell scripts except the cloud-init template
[group('check')]
check-no-shell:
    ! git ls-files '*.sh' '*.bash' '*.sh.tpl' '*.bash.tpl' | grep -vx infra/scripts/init.sh.tpl

# Go tests never read kubernetes/ YAML (invariants belong in the policy layer)
[group('check')]
check-no-manifest-tests:
    ! git grep -l 'kubernetes/' -- '*_test.go'

# Recipes stay short (.just/recipe-shape.awk) and formatted
[group('check')]
check-recipes:
    awk -f .just/recipe-shape.awk justfile
    just --fmt --check --unstable
