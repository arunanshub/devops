output "api_lb_private_ip" {
  description = "Private IPv4 of the API server load balancer within the cluster network."
  value       = local.lb_private_ip
}

output "api_lb_public_ipv4" {
  description = "Public IPv4 of the API server load balancer. Used as the kubeconfig endpoint and in Talos certSANs."
  value       = hcloud_load_balancer.api.ipv4
}

output "cluster_name" {
  description = "Cluster name prefix used for Hetzner server and Kubernetes node names."
  value       = local.cluster_name
}

output "node_ipv6_addresses" {
  description = "Public IPv6 addresses of all nodes, keyed by node name."
  value       = { for k, v in hcloud_server.nodes : k => v.ipv6_address }
}

output "node_private_ips" {
  description = "Private IPv4 addresses of all nodes within the cluster network."
  value       = { for k, v in var.nodes : k => v.private_ip }
}

output "tunnel_token" {
  description = "Cloudflare Tunnel token for cloudflared. Pipe through kubeseal via `just seal-cloudflared-token`."
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.main.token
  sensitive   = true
}
