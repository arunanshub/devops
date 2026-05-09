output "api_lb_public_ip" {
  description = "Public IPv4 of the API server load balancer. Reserved for future admin HA; current kubeconfig uses the bootstrap CP IPv6."
  value       = hcloud_load_balancer.api.ipv4
}

output "api_lb_private_ip" {
  description = "Private IPv4 of the API server load balancer within the cluster network."
  value       = local.lb_private_ip
}

output "node_ipv6_addresses" {
  description = "Public IPv6 addresses of all nodes, keyed by node name. Used for SSH access."
  value       = { for k, v in hcloud_server.nodes : k => v.ipv6_address }
}

output "node_private_ips" {
  description = "Private IPv4 addresses of all nodes within the cluster network."
  value       = { for k, v in var.nodes : k => v.private_ip }
}

output "kubeconfig_path" {
  description = "Local path where kubeconfig was written."
  value       = "${path.module}/kubeconfig.yaml"
}

output "bootstrap_node_ipv6" {
  description = "Public IPv6 of the bootstrap control plane used by the generated kubeconfig."
  value       = hcloud_server.nodes[var.bootstrap_node].ipv6_address
}
