# Hetzner publishes a Talos ISO (Hetzner + qemu-guest-agent schematic).
# On first boot the server boots from the ISO into Talos maintenance mode;
# talosctl apply-config installs Talos to disk. After reboot the node runs
# from disk — the ISO attachment becomes inert.
#
# Version upgrade path: talosctl upgrade (not tofu apply).
# The iso and image fields are ignored after initial creation to prevent
# accidental node replacement when the ISO name changes upstream.
resource "hcloud_server" "nodes" {
  for_each = var.nodes

  name        = "${local.cluster_name}-${each.key}"
  image       = "debian-12"
  iso         = "hcloud-v1-12-4.amd64.iso"
  server_type = each.value.server_type
  location    = each.value.location
  labels      = { cluster = local.cluster_name }

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  network {
    network_id = hcloud_network.main.id
    ip         = each.value.private_ip
  }

  delete_protection  = false
  rebuild_protection = false

  lifecycle {
    # iso: only relevant for first boot; upgrades go through talosctl upgrade.
    # image: overwritten by Talos installer; field has no meaning post-install.
    # prevent_destroy: re-enable after cluster is stable.
    ignore_changes  = [iso, image, user_data]
    prevent_destroy = false
  }

  depends_on = [
    hcloud_network_subnet.main,
    hcloud_load_balancer_network.api,
    hcloud_load_balancer_service.api,
  ]
}
