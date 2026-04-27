# Phase 2 — hardening
#
# Uncomment and fill in when Phase 2 begins.
# At that point var.home_ip must be set in secrets.yaml.
#
resource "hcloud_firewall" "main" {
  name = "${local.cluster_name}-firewall"

  # SSH — your IP only
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.home_ip]
  }

  # k3s API — your IP only
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = [var.home_ip]
  }

  # All other inbound is blocked by default (Hetzner firewall default-deny).
  # Outbound is unrestricted.
}

resource "hcloud_firewall_attachment" "main" {
  firewall_id = hcloud_firewall.main.id
  server_ids  = [hcloud_server.control_plane.id]
}
