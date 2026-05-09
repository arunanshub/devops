resource "hcloud_ssh_key" "main" {
  name       = "${local.cluster_name}-key"
  public_key = file(var.ssh_public_key_path)
}

resource "hcloud_server" "nodes" {
  for_each = var.nodes

  name        = "${local.cluster_name}-${each.key}"
  image       = "ubuntu-24.04"
  server_type = each.value.server_type
  location    = each.value.location
  ssh_keys    = [hcloud_ssh_key.main.id]
  labels      = { cluster = local.cluster_name }

  # IPv4 required: get.k3s.io (GitHub releases) is IPv4-only.
  # SSH and monitoring use IPv6 where available.
  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  network {
    network_id = hcloud_network.main.id
    ip         = each.value.private_ip
  }

  user_data = templatefile("${path.module}/scripts/init.sh.tpl", {
    k3s_config       = yamlencode(local.k3s_configs[each.key])
    k3s_version      = local.k3s_version
    is_bootstrap     = each.key == var.bootstrap_node
    is_control_plane = contains(keys(local.cp_nodes), each.key)
    lb_private_ip    = local.lb_private_ip
    lb_public_ip     = hcloud_load_balancer.api.ipv4
    node_private_ip  = each.value.private_ip
    role             = each.value.role
  })

  # Intentional friction: set these to true once the cluster carries real workloads.
  # tofu destroy will fail until explicitly set to false.
  delete_protection  = false
  rebuild_protection = false

  # Nodes need their private interface and the API LB address available before
  # cloud-init starts k3s with node-ip/server settings.
  depends_on = [
    hcloud_network_subnet.main,
    hcloud_load_balancer_network.api,
    hcloud_load_balancer_service.api,
  ]
}

# Retrieve kubeconfig from the bootstrap node and patch the server URL to that
# node's public IPv6. The cluster itself uses the private API LB for HA; admin
# access stays home-IP restricted until we intentionally switch to the LB.
resource "terraform_data" "kubeconfig" {
  triggers_replace = [hcloud_server.nodes[var.bootstrap_node].id]

  connection {
    type           = "ssh"
    user           = "root"
    agent          = true
    agent_identity = var.ssh_private_key_path
    host           = hcloud_server.nodes[var.bootstrap_node].ipv6_address
    timeout        = "5m"
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
          root@${hcloud_server.nodes[var.bootstrap_node].ipv6_address} \
          "cat /etc/rancher/k3s/k3s.yaml" \
        | sed 's|https://127.0.0.1:6443|https://[${hcloud_server.nodes[var.bootstrap_node].ipv6_address}]:6443|' \
        > ${path.module}/kubeconfig.yaml
      chmod 600 ${path.module}/kubeconfig.yaml
    EOT
  }
}
