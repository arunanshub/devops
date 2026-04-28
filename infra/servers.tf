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
  labels      = { cluster = local.cluster_name }

  # IPv4 required: get.k3s.io (GitHub releases) and image registries don't support IPv6.
  # SSH and kubectl use the IPv6 address since your Airtel connection is IPv6-capable.
  # ghcr.io has no IPv6 support — use Docker Hub images only for workloads.
  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  user_data = templatefile("${path.module}/scripts/init.sh.tpl", {
    k3s_version = local.k3s_version,
  })

  # Enable once the cluster has any real workload on it.
  # Intentional friction: tofu destroy will fail until you set these to false.
  # delete_protection  = true
  # rebuild_protection = true
}

resource "terraform_data" "k3s" {
  triggers_replace = [hcloud_server.control_plane.id]

  connection {
    type           = "ssh"
    user           = "root"
    agent          = true
    agent_identity = var.ssh_private_key_path
    host           = hcloud_server.control_plane.ipv6_address
    timeout        = "3m"
  }

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait",
      "k3s kubectl wait node --all --for condition=Ready --timeout=5m",
    ]
  }

  provisioner "local-exec" {
    command = <<-EOT
      ssh -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -i ${var.ssh_private_key_path} \
          root@${hcloud_server.control_plane.ipv6_address} \
          "cat /etc/rancher/k3s/k3s.yaml" \
        | sed "s/127.0.0.1/[${hcloud_server.control_plane.ipv6_address}]/" \
        > ${path.module}/kubeconfig.yaml
      chmod 600 ${path.module}/kubeconfig.yaml
    EOT
  }
}
