# Traefik Optimization Design

## Goal

Make the Traefik deployment valid for chart 41.1.0, preserve the public
dashboard behind Cloudflare Access, and improve availability, memory safety,
network isolation, and scaling behavior.

## Constraints

- Keep `traefik.arunanshu.dev` available.
- Keep Cloudflare Access as the only user authentication layer.
- Do not expose Traefik with a public Kubernetes Service.
- Keep two ready replicas during normal operation.
- Keep the current Gateway API and Traefik Middleware model.
- Add only changes that remove a measured problem or a specific failure mode.

## Changes

### Chart and GitOps correctness

- Migrate `logs.access` to the chart 41 `accessLog` syntax.
- Set `deployment.replicas: null` so KEDA owns the replica field.
- Remove the Argo CD replica ignore rule after the chart omits the field.
- Disable the unused Kubernetes Ingress provider and default IngressClass.
- Add a local render check that uses the pinned chart version and current
  values file.

### Availability

- Change the hostname topology spread rule to `DoNotSchedule`.
- Keep the rolling update policy at `maxUnavailable: 0`.
- Keep the current PodDisruptionBudget.
- Change the KEDA fallback behavior to `currentReplicasIfHigher`.

### Memory and resource use

- Restore the chart-managed `GOMEMLIMIT` at 90 percent of the fixed 1 GiB
  container limit.
- Keep VPA in `RequestsOnly` mode.
- Measure live CPU, memory, VPA recommendations, HPA state, request rate,
  errors, and pod placement before and after the rollout.
- Change requests, limits, or scaling thresholds only when the measurements
  support the change.

### Network isolation

- Keep the dashboard route behind the existing Cloudflare Access policy.
- Add a Cilium ingress policy for Traefik.
- Permit web traffic from cloudflared and approved in-cluster load-test pods.
- Permit the dashboard backend port from Traefik pods and host probes.
- Permit the metrics port from monitoring.
- Do not add BasicAuth.
- Do not add egress restrictions in this change.

### Argo CD failure alerts

- Export the existing application-controller metrics through a ServiceMonitor.
- Use the existing VictoriaMetrics and Alertmanager email path.
- Alert when an Application remains out of sync, becomes degraded, or stops
  exporting application state.
- Do not add Argo CD Notifications or another alert delivery system.

## Rollout

1. Record the live chart, pods, placement, resources, autoscalers, metrics, and
   route status.
2. Prove that the current chart 41 render fails.
3. Add focused checks for the corrected render and policy.
4. Apply the chart and scaling changes in Git.
5. Render chart 41.1.0 and build all related Kustomize resources.
6. Review the generated Deployment, Service, Gateway, RBAC, and policy.
7. Commit and push only after all local checks pass.
8. Watch Argo CD synchronization and the Traefik rolling update.
9. Confirm two ready replicas on different nodes, valid routes, metrics,
   traces, dashboard access, and no increase in errors.
10. Repeat the resource and traffic measurements.

## Rollback

Revert the implementation commit. Argo CD will restore the previous chart
values and related resources. If the new pods do not become ready, stop the
rollout before both old pods terminate. The rolling update policy keeps old
pods available while new pods fail readiness.

## Exclusions

- HTTP/3 at Traefik.
- Direct public load balancers or NodePorts.
- A second dashboard authentication system.
- FastProxy.
- New retry, circuit-breaker, or rate-limit middleware without service
  failure data.
- Backend timeout changes without evidence of stalled connections.
