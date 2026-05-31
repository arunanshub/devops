cloudflare_account_id = "2f120b3588f24bba8666100a3da52e02"
cloudflare_zone_id    = "9d7653ab8d3a31bc36ddebc0e9b02e96"
owner_email           = "mydellpc07@gmail.com"

bootstrap_node         = "cp-1"
is_cluster_initialized = false

# Cluster topology. To add a node: add an entry, run tofu apply.
# To remove a node: drain it first, then remove the entry and apply.
# CP count must remain odd.
# cx33 unavailable in hel1 — using cpx32 (same 4 vCPU / 8GB RAM spec).
nodes = {
  "cp-1" = { server_type = "cpx32", role = "cp_worker", location = "hel1", private_ip = "10.0.0.2" }
  "cp-2" = { server_type = "cpx32", role = "cp_worker", location = "hel1", private_ip = "10.0.0.3" }
  "cp-3" = { server_type = "cpx32", role = "cp_worker", location = "hel1", private_ip = "10.0.0.4" }
}
