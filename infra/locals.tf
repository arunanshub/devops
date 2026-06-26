locals {
  cluster_name = "hetzner-k3s"
  k3s_version  = "v1.36.2+k3s1"
  network_cidr = "10.0.0.0/16"
  subnet_cidr  = cidrsubnet(local.network_cidr, 8, 0)

  # Static private IP for the API server load balancer.
  # Sits outside the node IP range (.2–.9) so it's stable and auditable.
  lb_private_ip = "10.0.0.100"

  cp_nodes = { for k, v in var.nodes : k => v if contains(["cp_only", "cp_worker"], v.role) }

  # Replaced at first boot with the node's public IPv6 (assigned by Hetzner during creation).
  node_public_ipv6_san_marker = "__NODE_PUBLIC_IPV6__"

  k3s_configs = {
    for k, v in var.nodes : k => {
      for key, val in {
        "node-ip"                  = v.private_ip
        "token"                    = var.k3s_token
        "kubelet-arg"              = ["cloud-provider=external"]
        "flannel-backend"          = v.role != "worker" ? "none" : null
        "disable-kube-proxy"       = v.role != "worker" ? true : null
        "disable-network-policy"   = v.role != "worker" ? true : null
        "disable"                  = v.role != "worker" ? ["traefik", "servicelb"] : null
        "disable-cloud-controller" = v.role != "worker" ? true : null
        "tls-san" = v.role != "worker" ? [
          hcloud_load_balancer.api.ipv4,
          local.lb_private_ip,
          v.private_ip,
          local.node_public_ipv6_san_marker,
        ] : null
        "cluster-init" = (k == var.bootstrap_node && !var.is_cluster_initialized) ? true : null
        "server"       = (k == var.bootstrap_node && !var.is_cluster_initialized) ? null : "https://${local.lb_private_ip}:6443"
      } : key => val if val != null
    }
  }
}
