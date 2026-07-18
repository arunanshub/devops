# Cloudflared HTTP/2 Transport Experiment

## Status

Approved for implementation as a temporary, evidence-gathering experiment. HTTP/2 is not the presumed root cause or the intended permanent state.

## Context

On 2026-07-15, authenticated Grafana browsing experienced intermittent 6–18 second static-asset transfers, JavaScript `ChunkLoadError` failures, and a Cloudflare 520 response. The failed 520 request did not reach Traefik or Grafana, while the origin remained responsive. Current cloudflared logs also contain synchronized QUIC failures across separate replicas, including `timeout: no recent network activity`.

These observations make the Cloudflare-to-connector QUIC leg worth isolating, but they do not prove it is the cause. The cluster had operated on QUIC for an extended period before the visible incident, and a separate visitor-side IPv6 transfer problem was observed over both HTTP/2 and HTTP/3.

## Decision

Temporarily force the cloudflared connector transport to HTTP/2 by passing `--protocol http2` before `run` in the Deployment arguments.

This changes only the Cloudflare edge-to-cloudflared leg. It does not disable browser-facing HTTP/3 and does not change the cloudflared-to-Traefik origin protocol.

The experiment must be treated as falsifiable:

- Improvement supports further investigation of the connector QUIC path; it does not by itself prove QUIC was the sole cause.
- No improvement weakens the connector-QUIC hypothesis and shifts attention to the visitor IPv6/Cloudflare edge path.
- Regression is grounds for immediate reversion.

The default post-experiment state is `auto`. Keeping HTTP/2 requires a separate decision supported by the recorded observations.

## Repository Changes

### Deployment

Update `kubernetes/components/cloudflared/resources/deployment.yaml` to add:

```yaml
- --protocol
- http2
```

Place the arguments before `run`, alongside an inline comment that records:

- The experiment date and temporary nature.
- The observed QUIC timeout signature and Cloudflare 520 symptom.
- That browser-facing HTTP/3 is unaffected.
- Links to Cloudflare's protocol documentation, the upstream cloudflared QUIC latency issue, and the local operator document.

### Image pin

Do not change the cloudflared image version as part of this experiment. The persistent image pin remains owned by `kubernetes/components/cloudflared/resources/kustomization.yaml`, which selects cloudflared 2026.5.2 by both tag and digest. Keeping the binary constant isolates the transport protocol as the experimental variable.

### Operator documentation

Create `docs/cloudflare-tunnel-transport.md` with:

- A diagram or compact text description of the three network legs.
- The incident evidence and competing hypotheses.
- The exact experimental setting and attribution sources.
- Activation, observation, and rollback procedures.
- Success, inconclusive, and regression criteria.
- Queries and commands for verifying the active connector protocol and checking tunnel errors.

Add a short cross-reference from `docs/cloudflare-tunnel-pitfalls.md` rather than duplicating the runbook.

## Attribution

The manifest and operator document will cite primary sources:

- Cloudflare's `protocol` run-parameter documentation, which defines `auto`, `http2`, and `quic`, and states that `auto` selects QUIC with HTTP/2 fallback.
- Cloudflare's tunnel troubleshooting documentation, which recommends forcing HTTP/2 when testing UDP/QUIC connectivity problems.
- cloudflared issue #895, which reports QUIC response-time degradation and user-observed improvement when forcing HTTP/2. The issue is supporting context, not proof of this incident's cause.

The pinned cloudflared 2026.5.2 binary has also been checked locally: it accepts `--protocol http2` before `run`, although that version does not display the hidden flag in generated `--help` output.

## Observation Procedure

After the GitOps rollout completes:

1. Confirm both cloudflared replicas are Ready and report registered tunnel connections using `protocol: http2`.
2. Exercise the same authenticated Grafana workflows that exposed the incident, including cold/static chunk loads from more than one browser.
3. Observe for at least 60 minutes and capture:
   - Static-asset transfer latency, especially p95/p99 and individual multi-second stalls.
   - Cloudflare 5xx responses, particularly 520.
   - cloudflared request, stream, connection, and reconnect errors.
   - Traefik and Grafana origin latency to ensure any change is not origin-driven.
4. Record whether the visitor is using IPv4 or IPv6 because the earlier IPv6 stalls are a separate confounder.
5. Revert the manifest to `auto` after the observation window unless a separate decision explicitly extends the experiment.

## Evaluation Criteria

The experiment supports the connector-QUIC hypothesis only if comparable Grafana browsing no longer shows the previous multi-second tail stalls or 520 responses, while origin latency and workload remain comparable.

The result is inconclusive if the original symptom does not recur under either transport, the workload is not comparable, or visitor IP-family data is missing.

The experiment rejects or weakens the hypothesis if equivalent stalls continue over HTTP/2, particularly when correlated with visitor IPv6 while the tunnel and origin remain healthy.

## Rollback

Remove the explicit `--protocol http2` arguments to restore the current `auto` behavior. Re-render the Kustomize output, allow ArgoCD to roll the two replicas, and verify new tunnel registrations report `protocol: quic`.

Rollback immediately if either connector fails readiness, tunnel capacity drops, error rates increase, or user-visible latency worsens.

## Verification Before Deployment

- Render the production Kustomize overlay and confirm the Deployment contains the arguments in the intended order.
- Confirm the rendered image still uses the existing 2026.5.2 tag and digest from `kustomization.yaml`.
- Run the repository's YAML formatting checks.
- Re-run the pinned binary's non-mutating argument parser check.
- Review the diff to ensure unrelated working-tree changes are excluded.

Deployment is performed through the normal GitOps path: commit and push the scoped files, then let ArgoCD reconcile the cloudflared Deployment. Do not live-patch the Deployment.
