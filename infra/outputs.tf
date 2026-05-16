output "api_lb_private_ip" {
  description = "Private IPv4 of the API server load balancer within the cluster network."
  value       = local.lb_private_ip
}

output "cluster_name" {
  description = "Cluster name prefix used for Hetzner server and Kubernetes node names."
  value       = local.cluster_name
}

output "node_ipv6_addresses" {
  description = "Public IPv6 addresses of all nodes, keyed by node name. Used for SSH access."
  value       = { for k, v in hcloud_server.nodes : k => v.ipv6_address }
}

output "node_private_ips" {
  description = "Private IPv4 addresses of all nodes within the cluster network."
  value       = { for k, v in var.nodes : k => v.private_ip }
}

output "node_roles" {
  description = "Node role for each declared node, keyed by node key."
  value       = { for k, v in var.nodes : k => v.role }
}

output "ssh_private_key_path" {
  description = "Local private key path used for Ansible and kubeconfig retrieval."
  value       = var.ssh_private_key_path
}
