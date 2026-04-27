output "control_plane_ipv6" {
  description = "Public IPv6 address of the control plane node."
  value       = hcloud_server.control_plane.ipv6_address
}

output "kubeconfig_path" {
  description = "Local path where kubeconfig was written by the null_resource."
  value       = "${path.root}/kubeconfig.yaml"
}
