locals {
  cluster_name = "hetzner-k3s"
  k3s_version  = "v1.32.3+k3s1"
  # network CIDR for private networking. Must be large enough to accommodate all nodes and services.
  network_cidr     = "10.0.0.0/16"
  subnet_cidr      = cidrsubnet(local.network_cidr, 8, 0)
  control_plane_ip = cidrhost(local.subnet_cidr, 2)
}
