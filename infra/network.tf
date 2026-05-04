# Phase 4 — private networking
#
# Must be created before adding a second node. Do not defer until you need it.
resource "hcloud_network" "main" {
  name     = "${local.cluster_name}-network"
  ip_range = local.network_cidr
}

resource "hcloud_network_subnet" "eu_central" {
  network_id   = hcloud_network.main.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = cidrsubnet(local.network_cidr, 8, 0)
}
