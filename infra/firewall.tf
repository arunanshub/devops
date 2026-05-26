resource "hcloud_firewall" "main" {
  name = "${local.cluster_name}-firewall"

  # SSH — your IP only
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.home_ip]
  }

  # ICMP — ping and path MTU discovery from anywhere
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # Port 6443 lives in hcloud_firewall.control_plane_api so future workers do
  # not get an unnecessary public API rule.
}

resource "hcloud_firewall_attachment" "main" {
  firewall_id = hcloud_firewall.main.id
  server_ids  = values(hcloud_server.nodes)[*].id
}

