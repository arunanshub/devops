cloudflare_account_id = "2f120b3588f24bba8666100a3da52e02"
cloudflare_zone_id    = "9d7653ab8d3a31bc36ddebc0e9b02e96"
owner_email           = "mydellpc07@gmail.com"

# Cluster topology. All nodes are Talos control-plane+worker.
nodes = {
  "cp-1" = { server_type = "cx33", location = "hel1", private_ip = "10.0.0.2" }
  "cp-2" = { server_type = "cx33", location = "hel1", private_ip = "10.0.0.3" }
  "cp-3" = { server_type = "cx33", location = "hel1", private_ip = "10.0.0.4" }
}
