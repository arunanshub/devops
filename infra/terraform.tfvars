cloudflare_account_id = "TODO: paste from dash.cloudflare.com (top-right, Account ID)"
cloudflare_zone_id    = "TODO: paste from Websites → arunanshu.dev → Overview (API section)"
owner_email           = "arunanshu.biswas@safedep.io"

bootstrap_node         = "cp-1"
is_cluster_initialized = true

# Cluster topology. To add a node: add an entry, run tofu apply.
# To remove a node: drain it first, then remove the entry and apply.
# CP count must remain odd.
nodes = {
  "cp-1" = { server_type = "cx33", role = "cp_worker", location = "hel1", private_ip = "10.0.0.2" }
  "cp-2" = { server_type = "cx33", role = "cp_worker", location = "hel1", private_ip = "10.0.0.3" }
  "cp-3" = { server_type = "cx33", role = "cp_worker", location = "hel1", private_ip = "10.0.0.4" }
}
