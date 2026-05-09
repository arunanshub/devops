# ADR: Use Cilium VXLAN Tunnel Mode on Hetzner

Date: 2026-05-09

Status: Accepted

## Context

The HA k3s cluster runs on Hetzner Cloud servers attached to a Hetzner Cloud
Network. The cluster uses Cilium for kube-proxy replacement, Gateway API
support, Hubble, network policy, and future Cilium features.

The first HA bootstrap used Cilium native routing:

```yaml
routingMode: native
ipv4NativeRoutingCIDR: 10.42.0.0/16
autoDirectNodeRoutes: false
endpointRoutes:
  enabled: true
```

HCCM successfully created Hetzner Network routes for each node PodCIDR:

```text
10.42.0.0/24 -> 10.0.0.2
10.42.1.0/24 -> 10.0.0.4
10.42.2.0/24 -> 10.0.0.3
```

However, the nodes themselves did not have a route for the aggregate PodCIDR.
Remote pod traffic therefore followed the public default route instead of the
private network:

```text
10.42.2.190 via 172.31.1.1 dev eth0
```

This broke cross-node pod connectivity and surfaced as:

- `kubectl top nodes` reporting `Metrics API not available`
- Cilium health reporting partial cluster reachability
- API server access to the metrics-server pod hanging

Adding a temporary aggregate route on every node fixed the issue immediately:

```text
10.42.0.0/16 via 10.0.0.1 dev enp7s0
```

After that, `kubectl top nodes`, `kubectl top pods -A`, direct metrics-server
pod access, and Cilium health all recovered.

## Decision

Use Cilium tunnel mode with VXLAN:

```yaml
routingMode: tunnel
tunnelProtocol: vxlan
```

Keep Cilium Gateway API enabled and explicitly create the default Cilium
GatewayClass:

```yaml
gatewayAPI:
  enabled: true
  gatewayClass:
    create: "true"
```

Do not use Cilium native routing for now.

Do not add persistent host-level PodCIDR routes for native routing.

## Rationale

Hetzner Cloud Networks are routed private networks, not a flat L2 fabric. Native
routing is valid, but it makes node PodCIDR routing part of the node bootstrap
contract. That contract is understandable, but it is provider-specific host
networking and must be carried forever by the infrastructure layer.

VXLAN tunnel mode avoids this class of failure. Cross-node pod packets are
encapsulated inside node-to-node traffic over the private network. The underlay
only needs to route Hetzner private node IPs, which already works:

```text
10.0.0.0/16 via 10.0.0.1 dev enp7s0
```

This is also aligned with the two Hetzner k3s reference projects reviewed:

- `mysticaltech/terraform-hcloud-kube-hetzner` defaults to Flannel, and its
  Cilium routing mode default is `tunnel`.
- `vitobotta/hetzner-k3s` defaults to Flannel, and its Cilium defaults are
  `routingMode: tunnel` and `tunnelProtocol: vxlan`.

VXLAN is preferred over Geneve because it is the boring Cilium tunnel default,
is widely exercised, and we do not need Geneve's extensible metadata behavior.

## Consequences

Positive:

- No persistent host PodCIDR route management.
- No dependency on Hetzner injecting dynamic PodCIDR routes into guest leases.
- Better fit for immutable node replacement.
- Keeps Cilium, Gateway API, Hubble, kube-proxy replacement, and network policy.
- Aligns with proven Hetzner k3s defaults.

Negative:

- Adds overlay encapsulation overhead.
- Reduces effective MTU compared with pure native routing.
- Leaves native-routing performance optimizations for a later, explicit effort.

## Reconsider When

Revisit native routing only if:

- The cluster has a measured networking bottleneck caused by VXLAN overhead.
- We are willing to own a documented node/provider routing contract.
- We can validate the native route setup across node replacement, reboot,
  Cilium restart, HCCM restart, and future worker pools.

Until then, prefer boring correctness over native-routing performance.
