resource "hcloud_ssh_key" "main" {
  name       = "${local.cluster_name}-key"
  public_key = file(var.ssh_public_key_path)
}

resource "hcloud_server_network" "control_plane" {
  server_id  = hcloud_server.control_plane.id
  network_id = hcloud_network.main.id
  ip         = local.control_plane_ip
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
    k3s_version     = local.k3s_version,
    node_private_ip = local.control_plane_ip,
  })

  # Enable once the cluster has any real workload on it.
  # Intentional friction: tofu destroy will fail until you set these to false.
  delete_protection  = false
  rebuild_protection = false
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
      "until k3s kubectl get nodes >/dev/null 2>&1; do echo 'waiting for API server...'; sleep 5; done",
    ]
  }

  provisioner "local-exec" {
    command = <<-EOT
      ssh -o StrictHostKeyChecking=accept-new \
          -o UserKnownHostsFile=${path.module}/.ssh_known_hosts \
          -i ${var.ssh_private_key_path} \
          root@${hcloud_server.control_plane.ipv6_address} \
          "cat /etc/rancher/k3s/k3s.yaml" \
        | sed "s/127.0.0.1/[${hcloud_server.control_plane.ipv6_address}]/" \
        > ${path.module}/kubeconfig.yaml
      chmod 600 ${path.module}/kubeconfig.yaml
    EOT
  }
}
