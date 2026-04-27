resource "hcloud_ssh_key" "main" {
  name       = "${local.cluster_name}-key"
  public_key = file(var.ssh_public_key_path)
}

resource "hcloud_server" "control_plane" {
  name        = "${local.cluster_name}-cp-1"
  image       = "ubuntu-24.04"
  server_type = var.control_plane_server_type
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.main.id]

  # IPv6 only — no public IPv4.
  # Your Airtel connection is IPv6-capable so kubectl works directly.
  # ghcr.io has no IPv6 support — use Docker Hub images only.
  public_net {
    ipv4_enabled = false
    ipv6_enabled = true
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail

    # Fail loudly rather than silently installing the wrong version.
    curl -sfL https://get.k3s.io \
      | INSTALL_K3S_VERSION="${local.k3s_version}" \
        INSTALL_K3S_EXEC="server --cluster-init --disable traefik --disable servicelb" \
        sh -
  EOF

  # Enable once the cluster has any real workload on it.
  # Intentional friction: tofu destroy will fail until you set these to false.
  # delete_protection  = true
  # rebuild_protection = true
}

# Retrieve kubeconfig without manual SSH.
# Patches the server's public IPv6 address in automatically so kubectl works immediately.
resource "null_resource" "kubeconfig" {
  depends_on = [hcloud_server.control_plane]

  triggers = {
    server_id = hcloud_server.control_plane.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Wait for k3s to finish initialising before fetching kubeconfig.
      sleep 30
      ssh -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -i ${var.ssh_private_key_path} \
          root@${hcloud_server.control_plane.ipv6_address} \
          "cat /etc/rancher/k3s/k3s.yaml" \
        | sed "s/127.0.0.1/[${hcloud_server.control_plane.ipv6_address}]/" \
        > kubeconfig.yaml
      chmod 600 kubeconfig.yaml
    EOT
  }
}
