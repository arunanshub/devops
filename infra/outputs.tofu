output "server_ip" {
  value = hcloud_server.k3s.ipv4_address
}
