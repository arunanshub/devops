resource "hcloud_firewall" "main" {
  name = "${local.cluster_name}-firewall"

  # Talos API — your IP only (replaces SSH; Talos has no SSH daemon)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "50000"
    source_ips = [var.home_ip]
  }

  # ICMP — ping and path MTU discovery from anywhere
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_firewall_attachment" "main" {
  firewall_id = hcloud_firewall.main.id
  server_ids  = values(hcloud_server.nodes)[*].id
}

resource "hcloud_firewall" "control_plane_api" {
  name = "${local.cluster_name}-control-plane-api"

  # kube-API — your IP only; all nodes are control planes in Talos.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = [var.home_ip]
  }
}

resource "hcloud_firewall_attachment" "control_plane_api" {
  firewall_id = hcloud_firewall.control_plane_api.id
  server_ids  = values(hcloud_server.nodes)[*].id
}
