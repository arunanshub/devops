# API server load balancer
#
# Single stable endpoint for all API server traffic:
#   - External kubectl (public IP, port 6443)
#   - Cilium k8sServiceHost (private IP 10.0.0.100, port 6443)
#
# Intentionally separate from the ingress LB provisioned dynamically by hccm.

resource "hcloud_load_balancer" "api" {
  name               = "${local.cluster_name}-api-lb"
  load_balancer_type = "lb11"
  location           = "hel1"
  labels             = { cluster = local.cluster_name }
}

resource "hcloud_load_balancer_network" "api" {
  load_balancer_id = hcloud_load_balancer.api.id
  network_id       = hcloud_network.main.id
  ip               = local.lb_private_ip

  depends_on = [hcloud_network_subnet.main]
}

resource "hcloud_load_balancer_service" "api" {
  load_balancer_id = hcloud_load_balancer.api.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443

  health_check {
    protocol = "tcp"
    port     = 6443
    interval = 15
    timeout  = 10
    retries  = 3
  }
}

# All nodes are control planes in Talos — all are valid API server backends.
resource "hcloud_load_balancer_target" "api" {
  for_each = var.nodes

  type             = "server"
  load_balancer_id = hcloud_load_balancer.api.id
  server_id        = hcloud_server.nodes[each.key].id
  use_private_ip   = true

  depends_on = [hcloud_load_balancer_network.api]
}
