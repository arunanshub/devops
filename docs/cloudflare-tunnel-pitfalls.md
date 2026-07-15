# Cloudflare Tunnel Pitfalls

Lessons from deploying cloudflared as the cluster's ingress path via Cloudflare Zero Trust.

The temporary HTTP/2 connector-transport experiment, its incident evidence, and
its rollback procedure are documented in
[`cloudflare-tunnel-transport.md`](cloudflare-tunnel-transport.md).

---

## DNS records must be proxied

**Symptom.** Traffic reaches the tunnel but Cloudflare Access is never challenged — users hit the app directly.

**Cause.** `proxied = false` (or omitted) means Cloudflare resolves the CNAME to the tunnel but does not route through the Access layer. Access only intercepts traffic that flows through Cloudflare's proxy.

**Fix.** Always set `proxied = true` on tunnel DNS records:
```hcl
resource "cloudflare_dns_record" "wildcard" {
  proxied = true  # mandatory — without this, Access is bypassed
  ttl     = 1     # 1 = Auto (required when proxied)
}
```

---

## Gateway name is `traefik-gateway`, not `traefik`

**Symptom.** HTTPRoute is accepted but traffic returns 404 — the route never attaches to the Gateway.

**Cause.** The Traefik Helm chart names the Gateway `traefik-gateway` (not the release name `traefik`). The listener is named `web` on port 8000 (internal).

**Fix.** All HTTPRoute `parentRefs` in this cluster:
```yaml
parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: traefik-gateway
    namespace: traefik
    sectionName: web
```
Verify with `kubectl get gateway -n traefik`.

---

## HTTPRoutes perpetually out of sync

**Symptom.** ArgoCD shows HTTPRoutes as out of sync on every reconcile despite no manifest changes.

**Cause.** The Kubernetes API server defaults several fields that are omitted in minimal manifests: `parentRefs[].group`, `parentRefs[].kind`, `backendRefs[].group`, `backendRefs[].kind`, `backendRefs[].weight: 1`, and `rules[].matches: [{ path: { type: PathPrefix, value: / } }]`. ArgoCD sees the live state (with defaults) as different from the desired state (without them).

**Fix.** Include all defaulted fields explicitly in HTTPRoute manifests:
```yaml
parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: traefik-gateway
    namespace: traefik
    sectionName: web
rules:
  - matches:
      - path:
          type: PathPrefix
          value: /
    backendRefs:
      - group: ""
        kind: Service
        name: my-service
        port: 80
        weight: 1
```

---

## Bootstrap ordering — seal before push

**Symptom.** cloudflared pods stuck in `CreateContainerConfigError` — Secret not found.

**Cause.** `cloudflared/application.yaml` was pushed to git and ArgoCD applied the Deployment before `just seal-cloudflared-token` was run, so `cloudflared-tunnel-token` Secret never existed.

**Fix.** Mandatory order:
1. `just apply` — creates Cloudflare tunnel (Terraform)
2. `just seal-cloudflared-token` — writes `sealed-tunnel-token.yaml`
3. Add `sealed-tunnel-token.yaml` to `cloudflared/resources/kustomization.yaml`
4. Commit both files in one atomic commit
5. Push — ArgoCD applies the SealedSecret and Deployment together

---

## `tunnel_secret` is immutable

**Symptom.** After `tofu apply`, cloudflared can no longer authenticate — tunnel token becomes invalid.

**Cause.** If the `random_bytes.tunnel_secret` resource is ever destroyed or recreated, Terraform recreates the tunnel with a new secret, which invalidates the sealed token in git.

**Fix.** Use `random_bytes` with no keepers — Terraform generates it once and never regenerates:
```hcl
resource "random_bytes" "tunnel_secret" {
  length = 32
}
```
If the tunnel must be recreated, re-run `just seal-cloudflared-token` and commit the new SealedSecret.

---

## ArgoCD web UI works over the tunnel; CLI does not

**Symptom.** `argocd login argocd.arunanshu.dev` fails or hangs.

**Cause.** The ArgoCD CLI uses gRPC over HTTP/2. Cloudflare's HTTP proxy terminates and re-establishes connections, which disrupts bidirectional gRPC streams. The web UI uses HTTP/1.1 REST and works fine.

**Fix.** Use the tunnel for web UI only. For CLI, use `kubectl port-forward svc/argocd-server -n argocd 8080:80` or `just launch-argocd-ui`.

---

## SSE connections never establish through Zero Trust Tunnel

**Symptom.** A browser `EventSource` to a path behind Cloudflare Zero Trust never reaches `OPEN` state. The browser sees an immediate connection failure; cloudflared logs `stream N canceled by remote with error code 0`.

**Cause.** Prometheus's `/api/v1/notifications/live` (and any SSE endpoint that holds the connection open without sending data immediately) returns `200 OK + Transfer-Encoding: chunked` and then stays silent until an event fires. Cloudflare's Zero Trust edge sees a QUIC stream with only HEADERS and no DATA frames and cancels it as stalled — before the 200 OK reaches the browser.

`X-Accel-Buffering: no` does not help here: that directive works at the Cloudflare CDN/reverse-proxy layer but not at the QUIC/Zero Trust Tunnel layer.

**What was tried.** Adding `X-Accel-Buffering: no` via a Traefik `headers` Middleware on the SSE path. The header reaches the response (verified via Traefik API), but the stream is still canceled by the CF edge.

**Fix (none that avoids the limitation).** The correct fix is Prometheus sending a periodic SSE keepalive comment (`:\n\n`) to keep the QUIC stream active. Prometheus has no config knob for this, and injecting it via a Traefik plugin would require a custom plugin. The practical options are:

- Accept it. `notifications/live` carries only operational events (config reload, rule evaluation error). All Prometheus functionality — queries, alerts, rules, recording rules — works without it. The UI shows a connection-failed badge but is otherwise fully usable.
- Add a thin keepalive-injecting sidecar in front of Prometheus (complex, not worth it for homelab).
- A path-scoped CF Access bypass for the endpoint would work but trades a protocol limitation for a security hole.

**Current state.** Accepted as a known limitation. The `no-buffer` Traefik middleware remains on the route as a defensive measure in case Cloudflare ever respects it at the tunnel layer.

---

## Cloudflare Access OTP goes to the policy email, not the login email

**Symptom.** Login page appears, OTP form is submitted, no email is received.

**Cause.** Cloudflare Access silently discards the OTP if the submitted email does not match any `include` rule in the Access policy (anti-enumeration). The policy email and the email entered at login must be identical.

**Fix.** Verify `owner_email` in `infra/terraform.tfvars` matches the email you actually log in with, then `just apply` to push the updated policy.
