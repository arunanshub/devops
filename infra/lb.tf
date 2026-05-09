# API server load balancer — Phase 6
#
# This LB is the single stable endpoint for all API server traffic:
#   - Future external kubectl path (public IP, port 6443)
#   - Node join URLs for cp-2, cp-3, and any future nodes (private IP)
#
# It is intentionally separate from the ingress LB, which is provisioned
# dynamically by hcloud CCM when a Cilium Gateway resource is created.

resource "hcloud_load_balancer" "api" {
  name               = "${local.cluster_name}-api-lb"
  load_balancer_type = "lb11"

  # Colocate with the bootstrap node — LB and targets must be in the same
  # network zone (eu-central). Using bootstrap node's location avoids
  # hardcoding while keeping the value declarative.
  location = var.nodes[var.bootstrap_node].location

  labels = { cluster = local.cluster_name }
}

# Attach the LB to the private network with a stable, explicit IP.
# use_private_ip = true on targets means all backend traffic flows here,
# not over the public internet.
resource "hcloud_load_balancer_network" "api" {
  load_balancer_id = hcloud_load_balancer.api.id
  network_id       = hcloud_network.main.id
  ip               = local.lb_private_ip

  # The subnet must exist before the LB can be attached to the network.
  # Tofu cannot infer this from network_id alone.
  depends_on = [hcloud_network_subnet.main]
}

# TCP passthrough on 6443. No proxy protocol — the k3s API server handles
# TLS itself. A TCP health check is simpler and equally reliable here;
# the HTTPS /healthz endpoint requires auth which complicates LB config.
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

# One target per CP node. for_each on local.cp_nodes means workers are never
# added as API server backends.
resource "hcloud_load_balancer_target" "api" {
  for_each = local.cp_nodes

  type             = "server"
  load_balancer_id = hcloud_load_balancer.api.id
  server_id        = hcloud_server.nodes[each.key].id
  use_private_ip   = true

  # Both the LB and the server must be on the private network before the
  # target can be created with use_private_ip = true.
  depends_on = [
    hcloud_load_balancer_network.api,
  ]
}
