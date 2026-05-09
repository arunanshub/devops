locals {
  cluster_name = "hetzner-k3s"
  k3s_version  = "v1.35.4+k3s1"
  network_cidr = "10.0.0.0/16"
  subnet_cidr  = cidrsubnet(local.network_cidr, 8, 0)

  # Static private IP for the API server load balancer.
  # Sits outside the node IP range (.2–.9) so it's stable and auditable.
  lb_private_ip = "10.0.0.100"

  # Derived node set — used by lb.tf, firewall.tf, and k3s config below.
  cp_nodes = { for k, v in var.nodes : k => v if contains(["cp_only", "cp_worker"], v.role) }

  # Per-node k3s config objects. Null values are filtered so workers do not
  # receive server-only settings, while avoiding HCL conditional object issues.
  k3s_config_values = {
    for k, v in var.nodes : k => {
      "node-ip"                  = v.private_ip
      "token"                    = var.k3s_token
      "kubelet-arg"              = ["cloud-provider=external"]
      "flannel-backend"          = contains(keys(local.cp_nodes), k) ? "none" : null
      "disable-kube-proxy"       = contains(keys(local.cp_nodes), k) ? true : null
      "disable-network-policy"   = contains(keys(local.cp_nodes), k) ? true : null
      "disable"                  = contains(keys(local.cp_nodes), k) ? ["traefik", "servicelb"] : null
      "disable-cloud-controller" = contains(keys(local.cp_nodes), k) ? true : null
      "cluster-init"             = k == var.bootstrap_node ? true : null
      "server"                   = k == var.bootstrap_node ? null : "https://${local.lb_private_ip}:6443"
    }
  }

  k3s_configs = {
    for k, config in local.k3s_config_values : k => {
      for key, value in config : key => value if value != null
    }
  }
}
