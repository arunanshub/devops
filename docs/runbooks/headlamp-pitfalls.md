# Headlamp Pitfalls and Auth Notes

Lessons from adding Headlamp to the cluster.

---

## Chart repo URL is `kubernetes-sigs`, not `headlamp-k8s`

**Symptom.** ArgoCD fails to pull the chart; "chart not found" or repo unreachable.

**Cause.** The official chart repo moved to the `kubernetes-sigs` org. The old `headlamp-k8s` URL no longer hosts the chart.

**Fix.**
```yaml
sources:
  - repoURL: https://kubernetes-sigs.github.io/headlamp/
    chart: headlamp
```

---

## OIDC requires k3s API server changes — not just Headlamp config

**Symptom.** OIDC is configured in Headlamp values; login redirect works but every Kubernetes API call returns 401.

**Cause.** Headlamp doesn't proxy k8s API calls through its own service account when OIDC is enabled — it passes the OIDC ID token directly as the bearer token to the k8s API. The API server rejects it because it has no OIDC validator configured.

**Fix.** Two things must be configured together:

1. Headlamp values (SealedSecret for credentials):
```yaml
config:
  oidc:
    secret:
      create: false
      name: headlamp-oidc
```

2. k3s API server flags (via ansible `kube-apiserver-arg` in `config.yaml.d`):
```yaml
kube-apiserver-arg+:
  - "oidc-issuer-url=https://accounts.google.com"   # or GitHub, etc.
  - "oidc-client-id=<your-client-id>"
  - "oidc-username-claim=email"
```

OIDC provider recommendations for this cluster: **GitHub** or **Google** — well-known issuer URLs, no extra infra to run.

**Current state (temporary).** Token-based login is in use. Generate a long-lived token:
```bash
kubectl create token headlamp -n headlamp --duration=8760h
```
or a non-expiring bound secret:
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: headlamp-token
  namespace: headlamp
  annotations:
    kubernetes.io/service-account.name: headlamp
type: kubernetes.io/service-account-token
EOF
kubectl get secret headlamp-token -n headlamp -o jsonpath='{.data.token}' | base64 -d
```

---

## Cloudflare Access and Headlamp OIDC are different auth layers

**Common confusion.** "CF Access is already protecting `headlamp.arunanshu.dev` — isn't that OIDC?"

**Clarification.** They operate at different layers:

- **CF Access (perimeter)** — gates who can reach the URL at all. Already handles this via the wildcard `*.arunanshu.dev` policy in `infra/cloudflare.tf`. User authenticates with email OTP before traffic reaches Traefik.
- **Headlamp OIDC (k8s identity)** — gates what the user can do in the cluster. The OIDC token is used as the k8s API bearer token; RBAC controls what that identity can see/modify.

Both can coexist: CF Access for perimeter, OIDC for in-cluster identity. CF Access *can* act as an OIDC provider (via a `saas`-type Access application in Terraform), but it adds setup complexity versus GitHub/Google for a single-user cluster.

---

## KEDA is not appropriate for Headlamp

Headlamp is a low-traffic admin UI used by a handful of cluster operators. There is no meaningful event-driven or metric-based trigger that would cause it to scale. VPA handles right-sizing the single replica. Adding a KEDA `ScaledObject` would idle permanently at `minReplicaCount: 1`.

Scale-to-zero via the KEDA HTTP addon is possible but causes a cold-start delay every time the dashboard is opened — undesirable for an admin tool.
