locals {
  cluster_name = "hetzner-talos"
  network_cidr = "10.0.0.0/16"
  subnet_cidr  = cidrsubnet(local.network_cidr, 8, 0)

  # Static private IP for the API server load balancer.
  # Sits outside the node IP range (.2–.9) so it's stable and auditable.
  lb_private_ip = "10.0.0.100"
}
