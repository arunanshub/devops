# HA K3s Cluster Design

Date: 2026-05-09

## Goal

Move the Hetzner k3s cluster from a singleton control plane to a declarative three-node embedded-etcd control plane, while preserving the repo's operating discipline:

- replace nodes instead of repairing them by hand
- keep node state declarative through OpenTofu and cloud-init
- avoid routine operator SSH
- keep public Kubernetes API access restricted to `home_ip`
- make a future switch to public load-balanced admin access cheap

## Chosen Design

Use three k3s server nodes:

- `cp-1`: bootstrap server with `cluster-init: true`
- `cp-2`: joining server
- `cp-3`: joining server

All three currently use role `cp_worker`, so they can run both control-plane components and workloads. The topology is declared in `infra/terraform.tfvars` through `var.nodes`.

The cluster uses one Hetzner Load Balancer for the Kubernetes API:

- private address: `10.0.0.100`
- service: TCP `6443`
- targets: all control-plane nodes only
- backend traffic: private network via `use_private_ip = true`

This private LB is the stable API endpoint for cluster internals:

- joining control-plane nodes
- future workers
- Cilium's `k8sServiceHost`

## Admin Access Model

The initial admin-access model is Option B:

```text
kubectl from home -> bootstrap CP public IPv6:6443 -> kube-apiserver
cluster internals -> 10.0.0.100:6443 -> healthy CP node
```

Public `6443` is allowed only on control-plane nodes and only from `var.home_ip`.

The generated kubeconfig points to the bootstrap control plane's public IPv6, not the API load balancer public IP.

This is a deliberate tradeoff:

- cluster-internal API access is HA
- admin access remains home-IP locked
- admin access is not fully HA yet

If the bootstrap control plane is unavailable, the cluster should continue operating through the private API LB, but local admin access requires switching kubeconfig to another control-plane public IPv6.

## Future Public-LB Admin Path

The API load balancer keeps its public interface, and its public IP is included in each control-plane node's K3s TLS SAN list.

That makes this future transition cheap:

```text
kubectl from anywhere allowed by policy -> API LB public IP:6443 -> healthy CP node
```

To switch later:

1. Change kubeconfig generation to point at `hcloud_load_balancer.api.ipv4`.
2. Decide whether to remove direct public CP `6443` access.
3. Accept that Hetzner Cloud Firewalls cannot restrict the public LB to `home_ip`, or introduce a separate private-access layer first.

The TLS SAN is already prepared, so this future switch should not require rebuilding nodes just to satisfy certificate validation.

## Why Not WireGuard Or Tailscale Now

WireGuard or Tailscale would give a cleaner private admin path:

```text
kubectl -> private access network -> 10.0.0.100:6443
```

That is probably the long-term discipline-friendly model. It is deferred because it adds a separate access system before the HA control-plane design is fully understood and proven.

## Why Not Public API LB Now

A public API LB would provide true HA admin access immediately:

```text
kubectl -> API LB public IP:6443 -> healthy CP node
```

The issue is access control. Hetzner Cloud Firewalls cannot be attached to Load Balancers. Node firewalls also do not solve this when the LB targets nodes over the private network.

So a public API LB would make TCP `6443` reachable from the internet. Kubernetes authentication still protects the API, but this does not match the current home-IP-only discipline.

## OpenTofu Structure

The root module stays flat and declarative.

Key resources:

- `hcloud_server.nodes`: one server per `var.nodes` entry
- `hcloud_load_balancer.api`: stable API load balancer
- `hcloud_load_balancer_network.api`: private LB address `10.0.0.100`
- `hcloud_load_balancer_service.api`: TCP `6443`
- `hcloud_load_balancer_target.api`: one target per control-plane node
- `hcloud_firewall.main`: SSH and ICMP baseline
- `hcloud_firewall.control_plane_api`: public CP `6443` from `home_ip`
- `terraform_data.kubeconfig`: retrieves kubeconfig from bootstrap node and rewrites the server URL

Private node IPs are attached inside the `hcloud_server` resource's `network` block so cloud-init does not start k3s before the private interface exists.

## Validation Rules

The module validates:

- node roles are one of `cp_only`, `cp_worker`, or `worker`
- control-plane node count is odd
- node private IPs are unique
- bootstrap node exists
- bootstrap node has a control-plane role
- every node private IP is a usable host IP inside `local.subnet_cidr`
- the API LB private IP is a usable host IP inside `local.subnet_cidr`
- the API LB private IP does not collide with any node private IP

## K3s Config Shape

All nodes receive:

- `node-ip`
- shared `token`
- `kubelet-arg: cloud-provider=external`

Control-plane nodes additionally receive:

- `flannel-backend: none`
- `disable-kube-proxy: true`
- `disable-network-policy: true`
- `disable-cloud-controller: true`
- `disable: [traefik, servicelb]`
- TLS SANs for:
  - API LB public IPv4
  - API LB private IPv4
  - node private IPv4
  - node public IPv6

Only the bootstrap node receives:

- `cluster-init: true`

All other nodes receive:

- `server: https://10.0.0.100:6443`

## Cilium Requirements

Cilium must point at the private API load balancer:

```yaml
k8sServiceHost: 10.0.0.100
k8sServicePort: 6443
```

The bootstrap Cilium values and ArgoCD Cilium values must stay equivalent, because the repo relies on helmfile bootstrap followed by ArgoCD adoption.

For three control-plane nodes, Cilium operator replicas are set to `2`.

During bootstrap, hccm must install before Helm waits for the Cilium release to become fully ready. Nodes start with the external-cloud-provider taint:

```text
node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule
```

hccm tolerates that taint and removes it after initializing the nodes. Cilium's DaemonSets can run while the taint exists, but Hubble relay/UI and CoreDNS are ordinary pods and will remain Pending until hccm removes the taint. Therefore the bootstrap order is:

```text
gateway-api-crds + hccm -> cilium -> argocd
```

## Expected Plan Shape

The current migration intentionally rebuilds the old singleton control-plane server instead of preserving it through state moves.

A refreshless plan is expected to include:

- creation of the API load balancer and targets
- creation of three `hcloud_server.nodes` instances
- creation of the control-plane API firewall
- destruction of old singleton resources:
  - `hcloud_server.control_plane`
  - `hcloud_server_network.control_plane`
  - `terraform_data.k3s`

This is acceptable because the chosen migration is a rebuild, not an in-place live migration.

## Deferred Work

- Private admin access through WireGuard, Tailscale, or another explicit private-access layer
- Fully HA admin access while preserving home-IP or private-access restrictions
- Worker-only node pool
- Cluster Autoscaler
- Terragrunt or state layering if the flat module becomes painful
- Backup and restore drill before treating the cluster as durable
