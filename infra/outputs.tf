output "control_plane_ipv6" {
  description = "Public IPv6 address of the control plane node."
  value       = hcloud_server.control_plane.ipv6_address
}

output "kubeconfig_path" {
  description = "Local path where kubeconfig was written by the null_resource."
  value       = "${path.module}/kubeconfig.yaml"
}

output "control_plane_private_ipv4" {
  description = "Private IPv4 of the control plane on the Hetzner network."
  value       = hcloud_server_network.control_plane.ip
}
