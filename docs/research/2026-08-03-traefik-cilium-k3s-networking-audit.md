# Traefik, Cilium, and K3s networking audit — 2026-08-03

## Scope and method

This is an evidence-backed review of the effective edge path:

```text
Internet -> Cloudflare Access / Tunnel -> cloudflared -> Traefik Gateway -> HTTPRoute -> Service -> Pod
```

I inspected the checked-in manifests, rendered Traefik chart `41.1.0` and
Cilium `1.20.0`, read the current Kubernetes objects, and ran non-mutating
runtime checks on the three control-plane nodes. No test route, packet, or
workload was created. “Confirmed” therefore means that configuration and/or
runtime state proves the condition; it does not imply a destructive proof.

The local checkout is five commits behind `origin/master`. Its Cilium revision
still says `1.20.0-rc.1`, while the current GitOps source and deployed
application are `1.20.0`. Render conclusions below use the deployed stable
release, not the stale checkout revision. Do not apply Cilium from this
checkout until it is updated.

## Outcome

The core dataplane is healthy and internally coherent: kube-proxy replacement,
VXLAN, WireGuard pod-to-pod encryption, BPF masquerading, BBR, and PMTU
discovery are all enabled and live. Traefik shutdown timing also fits its pod
grace period. A later runtime check found that the optional WireGuard
node-to-node extension is opted out on every control-plane node; see the
second-pass finding below.

The material concerns are trust-boundary design, not a broken overlay:

1. The shared Gateway accepts routes from every namespace, while `www` is
   deliberately public. This turns namespace write access into public-route
   publication authority unless RBAC/GitOps makes every namespace equally
   trusted.
2. Traefik has ingress policy only, so its egress is unrestricted by Cilium.
3. Etcd metrics are configured and proven to listen on a private node address;
   the repository's stated Hetzner Firewall protection for private-network
   traffic is incorrect.
4. There is no host firewall policy, so Cilium does not constrain node-host
   listeners such as the exposed etcd metrics socket.

## Findings

### 1. A shared public listener makes namespace route creation a publication privilege

**Status:** mitigated in desired state; pending normal Argo CD reconciliation.

**Evidence.** At audit time,
`kubernetes/base/platform/traefik/values.yaml` configured the `web` Gateway
listener with `namespacePolicy.from: All`; the rendered Gateway had
`allowedRoutes.namespaces.from: All`, and live status showed seven attached,
accepted cross-namespace routes. Desired state now renders an explicit
namespace-name selector containing every current route namespace. The tunnel
configuration in `infra/cloudflare_tunnel.tf` sends the apex and wildcard
`*.arunanshu.dev` traffic to Traefik. In
`infra/cloudflare_access.tf`, `www.arunanshu.dev` has a public bypass. A
non-mutating external probe confirmed `www` reaches the public application,
while `traefik.arunanshu.dev/dashboard/` gets a Cloudflare Access redirect.

Gateway API permits this configuration: `from: All` allows routes from every
namespace. See [Traefik's Gateway API reference](https://doc.traefik.io/traefik/v3.7/reference/routing-configuration/kubernetes/gateway-api/).

**Impact.** If a principal can create both a `Service` and `HTTPRoute` in any
namespace that is less trusted than the public web application, it can publish
that service under `www.arunanshu.dev` through the existing public Access
bypass. This is an authorization-boundary escalation, not an unauthenticated
Internet-to-cluster bypass. If only cluster administrators or a tightly
reviewed GitOps controller can create routes, the risk is accepted policy rather
than an immediate vulnerability.

**Concrete safe proof input — not applied.**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: redteam-echo
  namespace: <namespace-you-can-write>
spec:
  selector: {app: redteam-echo}
  ports: [{port: 8080, targetPort: 8080}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: public-via-www
  namespace: <namespace-you-can-write>
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
      sectionName: web
  hostnames: ["www.arunanshu.dev"]
  rules:
    - backendRefs: [{name: redteam-echo, port: 8080}]
```

**Applied mitigation.** Desired state now uses `from: Selector` on the shared
listener and selects the six namespaces that own all seven currently accepted
routes (`arunanshu-dev`, `argocd`, `headlamp`, `kube-system`, `monitoring`, and
`traefik`) through Kubernetes' immutable namespace-name label. A new namespace
can no longer attach an HTTPRoute to this Gateway without an explicit policy
change. This does not split the public `www` hostname from protected hostnames:
write access in one of those six trusted namespaces remains publication
authority, by design. A separate public listener is a future stricter boundary
if those namespaces cease to share an edge-administrator trust level.

### 2. Traefik's Cilium policy does not restrict its egress

**Status:** mitigated in desired state; pending normal Argo CD reconciliation.

**Evidence.** At audit time,
`kubernetes/components/network-policies/resources/traefik-netpol.yaml`
contained `ingress` rules but no `egress` rules. The only live Cilium policies
were the Traefik and cloudflared policies; there was no
`CiliumClusterwideNetworkPolicy`. Desired state now contains two Traefik egress
rules. Cilium's policy model enables default-deny only for the direction covered
by a selecting policy: an ingress-only policy does not make egress default-deny.
See [Cilium policy enforcement](https://docs.cilium.io/en/latest/security/network/policyenforcement/)
and [network policy semantics](https://docs.cilium.io/en/latest/network/kubernetes/policy/).

**Impact.** A compromised Traefik pod may originate connections to any
destination that does not itself deny Traefik ingress. This weakens the value of
cloudflared's well-scoped egress policy and makes Traefik an edge-to-cluster
pivot point.

**Applied mitigation.** After narrowing route publication in finding 1, the
policy now enables egress default-deny and permits only the private Kubernetes
API load balancer on TCP/6443 and endpoints in those same six namespaces. This
covers the current direct-pod HTTPRoute backends, CoreDNS, Tempo tracing, and
Traefik's `api@internal` dashboard without allowing the Internet or unrelated
namespaces. It is intentionally namespace-scoped rather than service-scoped:
a permitted namespace remains a shared trust boundary. Add a namespace to both
the Gateway selector and this egress policy before attaching future routes.

### 3. Etcd metrics are exposed on the private network without the stated firewall boundary

**Status:** confirmed.

**Evidence.** `nodes/control-plane/etc/rancher/k3s/config.yaml.d/etcd-expose-metrics.yaml`
enables `etcd-expose-metrics: true`; its comment makes the same private-network
firewall assumption. A read-only `ss -ltnH` check on a control-plane host returned:

```text
LISTEN 10.0.0.4:2381 0.0.0.0:*
LISTEN 127.0.0.1:2381 0.0.0.0:*
```

The accompanying repository comment says the private network is protected by a
Hetzner Firewall. Hetzner explicitly states that Cloud Firewalls cannot secure
private Cloud Networks in its [Firewall FAQ](https://docs.hetzner.com/cloud/firewalls/faq/).
Its [network overview](https://docs.hetzner.com/networking/networks/overview/)
describes the private network as direct L3 connectivity, not a host firewall;
its [network FAQ](https://docs.hetzner.com/networking/networks/faq/) also notes
that private-network traffic is not automatically encrypted.

**Impact.** A server or workload able to send traffic on the private network can
reach the unauthenticated etcd metrics listener. This is not an etcd data-write
or quorum compromise by itself, but it exposes operational and topology data
and the trust argument for the listener is false.

**Fix/simplification.** Prefer disabling `etcd-expose-metrics` unless it is
actively scraped. If it must remain, enforce the boundary on each host with
`nftables`/UFW or a carefully rolled out Cilium host-firewall policy that allows
only the real monitoring source path. Do not rely on a Hetzner Cloud Firewall
for traffic on `10.0.0.0/16`.

### 4. Cilium does not currently protect node-host listeners

**Status:** confirmed.

**Evidence.** Cilium values enable pod policy enforcement but do not enable
`hostFirewall.enabled`, and no `CiliumClusterwideNetworkPolicy` exists. Cilium
documents that host policies require enabling the host firewall and selecting
the nodes with a clusterwide policy; pod policies do not cover all host-network
traffic. See [Cilium host firewall documentation](https://docs.cilium.io/en/latest/security/policy/host/).

**Impact.** This is directly relevant to finding 3 and to any future node port
or daemon bound on the private network. It is not evidence that public SSH or
the K3s API are exposed: their public exposure is separately constrained in
`infra/firewall.tf`.

**Fix/simplification.** First inventory all non-loopback host listeners and
decide which need private reachability. Then either use ordinary host firewall
rules (the least surprising approach for three nodes) or enable Cilium host
firewall in audit mode followed by a narrow `CiliumClusterwideNetworkPolicy`.
Roll one control-plane node at a time; a broad default-deny host policy can
break SSH, kubelet, or Cilium itself.

### 5. Overlay, WireGuard pod encryption, BPF, and MTU settings are coherent

**Status:** confirmed for control-plane configuration and local interface
state; end-to-end payload ceiling remains untested.

**Evidence.** `kubernetes/base/infra/cilium/values.yaml` uses tunnel routing,
VXLAN, WireGuard encryption, BPF masquerade, BBR, and PMTU discovery with
`pmtuDiscovery: always`. The live Cilium ConfigMap matches this. Every agent is
ready; `cilium-dbg status --brief` reports `OK`, and encryption status reports
WireGuard with two peers. On each node, `enp7s0` and `cilium_vxlan` are MTU
1450, `cilium_wg0` is MTU 1355, and TCP congestion control is BBR. The Cilium
agent's MTU reconcilers report those values.

The 95-byte reduction from 1450 to 1355 is consistent with WireGuard overhead.
With VXLAN nested over that route, approximately 1305 bytes remain for an
inner IP packet. That explains why pod interfaces retain 1450 but cross-node
traffic depends on PMTU discovery/MSS clamping. Cilium documents WireGuard node
encryption and PMTU behavior in its [WireGuard guide](https://docs.cilium.io/en/latest/security/network/encryption-wireguard/).

**Impact.** No configuration conflict was found. The double overlay adds
overhead and troubleshooting complexity, but it is functioning as configured
and provides both encapsulated routing and node-to-node encryption.

**Fix/simplification.** Keep the current setting unless measurements show a
real throughput/latency problem. Do not hard-code a lower pod MTU merely from
static arithmetic. Run the existing `just verify-mtu` only in an approved
restricted test namespace to prove the current cross-node ceiling and PMTU
failure handling; it creates temporary pods, so it was outside this read-only
audit.

### 6. Traefik termination timing is internally consistent; no timeout exploit was demonstrated

**Status:** confirmed for configuration consistency; uncertain for application
traffic adequacy.

**Evidence.** The rendered Traefik chart receives
`requestAcceptGraceTimeout=5s` and `graceTimeOut=50s`; its pod termination
grace period is 60 seconds. The deployment uses `maxUnavailable: 0` and
`maxSurge: 1`; the two live Traefik pods are ready on different control-plane
nodes. Cloudflared has three healthy replicas, one on each control-plane node.

**Impact.** The accept-plus-drain interval fits the 60-second pod deadline and
the rollout settings preserve an available replica. No configuration evidence
shows that an arbitrary request/response timeout is missing or unsafe. Adding
a short global timeout could break long dashboard queries, streaming, or slow
uploads.

**Fix/simplification.** Retain the current termination values. Decide any
response/read-idle timeout from access logs and connection-duration metrics,
then apply a documented limit per traffic class rather than a single global
number. Traefik's entrypoint timeout and forwarded-header behavior are
documented in its [entrypoint reference](https://doc.traefik.io/traefik/v3.7/reference/install-configuration/entrypoints/).

### 7. Forwarded client IP is safely untrusted but may be operationally incomplete

**Status:** confirmed.

**Evidence.** The Traefik values contain no `forwardedHeaders.trustedIPs` and
do not enable insecure forwarded headers. Traefik therefore does not trust
client-supplied forwarding headers by default. Its documentation says that
trusted IPs must be configured for the proxy source; `insecure` trusts all
sources. See [Traefik entrypoint forwarded headers](https://doc.traefik.io/traefik/v3.7/reference/install-configuration/entrypoints/).

**Impact.** This is not an IP-spoofing vulnerability: the current default is
safe. It can be an observability or application-correctness gap if rate limits,
logs, or applications need the original client address sent by Cloudflare.

**Fix/simplification.** Keep the current setting if backend client IP is not
needed. If it is needed, trust only the actual cloudflared source addresses and
validate the observed header chain first; never set `insecure: true`. Avoid
using the full pod CIDR as a permanent trust anchor, since another pod could
later send forged headers from that range.

### 8. K3s high-availability bootstrap settings are consistent; broader host hardening is not proven

**Status:** confirmed for the reviewed cluster-generation settings; uncertain
for live host-hardening controls not queried in this audit.

**Evidence.** All three control planes are Ready and run K3s `v1.36.2+k3s1`.
Generated flags consistently disable flannel, kube-proxy, K3s network policy,
Traefik, ServiceLB, and the cloud controller, leaving Cilium and GitOps as the
single owners. Control-plane operations are serial and include readiness/Cilium
health checks. K3s documents that repeated critical configuration values must
match across servers in [configuration](https://docs.k3s.io/installation/configuration).

**Impact.** There is no observed K3s/Cilium ownership conflict. Source does
not show flags for secrets encryption, audit policy, or protect-kernel-defaults,
but absence from this source review is insufficient to claim their absence on
each live host.

**Fix/simplification.** Keep one explicit owner for each function. Before
claiming a hardened K3s baseline, inventory the live K3s config drop-ins for
encryption, audit, admission, and kubelet/kernel settings, then compare it with
the [K3s hardening guide](https://docs.k3s.io/security/hardening-guide). This
is a separate host-hardening work item, not evidence of a networking incident.

## Explicit failed bypass attempt

I tested a host/SNI mismatch at the public edge: connect using the `www`
endpoint while sending `Host: traefik.arunanshu.dev`. Cloudflare Access still
returned its redirect. I could not bypass the protected dashboard with that
input. The dashboard remains intentionally protected at the Cloudflare layer;
Traefik's dashboard guidance also recommends securing it rather than exposing
it directly ([documentation](https://doc.traefik.io/traefik/v3.7/reference/install-configuration/api-dashboard/)).

## Priority order

1. Decide who may publish a public hostname, then split/narrow Gateway listener
   route namespaces accordingly.
2. Remove or host-firewall the private etcd metrics listener.
3. Decide the Traefik egress security model after narrowing backend/route
   authority.
4. Inventory node-host listeners before introducing Cilium host policy.
5. Run the existing controlled MTU verifier when temporary pod creation is
   acceptable.

## Second pass: performance and simplification

This pass re-read the current GitOps values, the live Cilium ConfigMap and
agent status, the rendered Traefik arguments, the K3s drop-ins, and current
VictoriaMetrics data. It was specifically intended to find controls that cost
resources or complexity without providing the intended protection.

### 9. Control-plane node opt-out is expected; pod encryption remains active

**Status:** confirmed, expected behavior; not a defect.

**Evidence.** `kubernetes/base/infra/cilium/values.yaml` sets
`encryption.nodeEncryption: true`. All three live Cilium agents instead report
`NodeEncryption: OptedOut` while retaining two WireGuard peers. Each Kubernetes
node has the standard `node-role.kubernetes.io/control-plane` label. Cilium
documents that its default node-encryption opt-out selector includes that label;
it also documents node-to-node encryption as beta and says forcing encryption
for those nodes needs manual CiliumNode public-key maintenance. See [Cilium
WireGuard encryption](https://docs.cilium.io/en/stable/security/network/encryption-wireguard/).

**Impact.** Cross-node managed-pod traffic remains WireGuard-encrypted; this is
the expected and working pod dataplane. Node-to-node, node-to-pod, and
pod-to-node traffic do not receive the optional node-encryption extension while
every node is also a control-plane. In particular, this setting does not protect
the exposed etcd metrics listener in finding 3. This is a trust-boundary fact to
document, not evidence of a Cilium malfunction.

**Fix/simplification.** Keep `nodeEncryption: true` if it is intentional future
worker-node coverage; worker nodes without the opt-out label can use the
extension. Otherwise it is optional configuration noise, not an urgent change.
Document that current WireGuard coverage is cross-node pod traffic only. If
host traffic must be encrypted now, do not merely override the opt-out label:
first design and test the required CiliumNode public-key maintenance and a
one-node-at-a-time failure/rollback procedure.

### 10. The standalone Cilium Envoy DaemonSet has no current consumer

**Status:** implemented in desired state; pending normal Argo CD reconciliation.

**Evidence.** Before this change, `envoy.enabled` was not set in the Cilium
values, so the chart's new-install default created `cilium-envoy`. Three live
Envoy pods consumed about 56 MiB and 11 millicores combined at the sample time
(requests reserved 100 MiB and 25 millicores per node). Cilium reported
`0 redirects active` and
`Envoy: external`. The desired and live CiliumNetworkPolicies contain no L7
HTTP, DNS, Kafka, TLS, or FQDN rules; no Cilium Envoy configuration resource is
installed; and Cilium Gateway API is disabled. Hubble flow metrics do not
require this standalone Envoy. Cilium documents that standalone Envoy is for
L7 policy/visibility or Cilium Ingress/Gateway API and that it is enabled by
default for new installs. See [Cilium Envoy](https://docs.cilium.io/en/latest/security/network/proxy/envoy/)
and the [Helm reference](https://docs.cilium.io/en/stable/helm-reference/).

**Impact.** The DaemonSet is an avoidable three-pod resource and upgrade
surface today. It is small relative to the cluster, but it provides no observed
traffic handling or isolation benefit.

**Applied simplification.** Desired state now sets `envoy.enabled: false` in
both the bootstrap and Argo CD values and removes the orphaned
`vpa-cilium-envoy.yaml` from the VPA kustomization. Exact-chart rendering and
the bootstrap-to-Argo adoption verifier both pass. Re-enable Envoy before
adding Cilium L7 policy, CiliumEnvoyConfig, Cilium Gateway API, or Cilium
Ingress. This removes the pods without weakening the present L3/L4 policies or
Traefik Gateway once Argo CD reconciles it.

### 11. Traefik router metrics are a measurable, conditional storage optimization

**Status:** conditional.

**Evidence.** Traefik runs a 15-second ServiceMonitor interval with router,
service, and entrypoint labels. The current database has 2,700 Traefik series:
76 router request counters plus 684 router histogram buckets, 74 service
counters plus 666 service histogram buckets, and 42 entrypoint counters plus
378 entrypoint histogram buckets. Router metrics therefore account for about
760 active series before associated gauges and scrape labels. Traefik documents
router labels as optional; the chart default is off.

`traefik-scaling` uses service metrics, but
`kubernetes/base/apps/arunanshu-dev/resources/scaledobject.yaml` uses
`traefik_router_request_duration_seconds_sum`. The last 24 hours show identical
router/service request counts (1,381) but slightly different summed durations
(74.45 vs 74.11 seconds), because router time includes routing/middleware work
that backend service time does not.

**Impact.** Turning `addRoutersLabels` off now would break the application
scaler. Keeping it costs database memory, storage, and scrape work, but the
current volume is not a demonstrated bottleneck: Traefik is using only 1–2
millicores per pod and 40–46 MiB memory.

**Fix/simplification.** Do not remove it blindly. If the application scaler can
use service time, change its query to the exact `exported_service` selector,
recalibrate its threshold against a representative load test, and compare
desired replicas with the current router-based trigger. Only then set
`addRoutersLabels: false`. This would remove roughly 28% of current Traefik
series without weakening edge security. Keep router metrics if per-route
latency debugging is worth that small cost.

### 12. Do not tune Cilium map sizing, Hubble retention, or routing mode from the current data

**Status:** confirmed no-change recommendation.

**Evidence.** Maximum live Cilium BPF map pressure is only 3.5% for the IPv4
connection-tracking map; all other reported maps are below 1.4%. Explicit map
sizing would spend memory without solving pressure. Hubble processes about 233
events/second. Its 4,095-entry history ring is full and overwrites roughly 0.6
old events/second, but there are zero losses from the observer event queue and
the kernel perf ring. This is bounded-history turnover, not datapath loss.

Replacing VXLAN with native routing would remove one encapsulation layer, but
Hetzner Cloud Networks are private L3 links, not a shared L2 segment. Cilium
auto-direct routing needs direct route reachability; using native routing here
would require maintaining pod-CIDR routes through cloud-server gateways.
That adds a routing dependency and failure mode for a three-node cluster.
See [Hetzner Network architecture](https://docs.hetzner.com/networking/networks/technical-concepts/architecture/)
and [Cilium routing modes](https://docs.cilium.io/en/stable/network/concepts/routing/).

**Impact and recommendation.** Leave the automatic BPF map sizing, Hubble
buffer, VXLAN, WireGuard pod encryption, BBR, and PMTU discovery unchanged.
The measured state does not support a performance-driven dataplane rewrite.

### 13. The unused Traefik TLS entrypoint is minor configuration dead weight

**Status:** implemented in desired state; pending normal Argo CD reconciliation.

**Evidence.** The chart creates `websecure` on :8443 and a ClusterIP Service
port 443 by default. Desired state now disables that Service exposure, and an
exact chart render contains only Service port 80. The only Gateway listener is
HTTP on port 8000, cloudflared forwards both public host rules to
`http://traefik...:80`, and the Traefik Cilium policy has no allow rule for
8443. There is no current legitimate path to that entrypoint. The chart
documents all standard entrypoints as defaults.

**Impact.** It is not a meaningful CPU or memory cost and is already blocked by
policy, but it leaves a misleading internal Service port and an unnecessary
TLS listener configuration.

**Applied simplification.** Desired state sets
`ports.websecure.expose.default: false`, so the generated `traefik` Service no
longer publishes port 443. The chart still starts the default listener, so no
custom listener override was added. This is hygiene, not a performance
priority.

### 14. `nativeLBByDefault` would make the current backend path slower, not more native

**Status:** do not enable globally.

**Evidence.** The installed Traefik values enable only the Kubernetes Gateway
provider and do not set `providers.kubernetesGateway.nativeLBByDefault`; its
default is therefore in use. Traefik's terminology is counterintuitive here:
the default sends requests directly to ready pod IPs and reuses backend
connections for performance. Setting `nativeLBByDefault: true` changes every
Gateway backend to connect to the Kubernetes Service `ClusterIP`, so the
Service dataplane selects a pod instead. This is documented in [Traefik's
Gateway API native load-balancing reference](https://doc.traefik.io/traefik/v3.7/reference/routing-configuration/kubernetes/gateway-api/).

The live Cilium dataplane has socket load-balancing disabled (`bpf-lb-sock:
false`). Thus the Service-IP version adds Cilium's Service lookup/translation to
each Traefik backend connection; it cannot remove a hop. No routed HTTP backend
has the per-Service `traefik.io/service.nativelb: "true"` annotation, and there
is no routed backend that currently requires Kubernetes `internalTrafficPolicy:
Local`, Service session affinity, or topology-aware endpoint selection.

**Impact.** A global change would alter every HTTPRoute silently, add an
otherwise unnecessary Service dataplane step, and may produce less even
replica use because Traefik still reuses established connections. It gives no
extra encryption, client-IP preservation, NetworkPolicy protection, or
availability benefit in this cluster.

**Recommendation.** Keep the direct-pod default. If one future backend needs
Service-level routing semantics, put `traefik.io/service.nativelb: "true"` on
that individual Service, test distribution and failure behaviour for that one
route, and leave the global provider default unchanged. Do not enable Cilium
socket LB merely to justify this option: it is a distinct dataplane change with
no demonstrated bottleneck.
