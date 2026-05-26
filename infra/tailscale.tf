provider "tailscale" {
  api_key = var.tailscale_api_key
  tailnet = var.tailscale_tailnet
}

# Manage the full tailnet ACL policy. This is the entire policy document —
# adding tag:k3s-operator to tagOwners so the operator can self-assign it.
resource "tailscale_acl" "main" {
  acl = jsonencode({
    tagOwners = {
      "tag:k3s-operator" = ["autogroup:admin"]
    }
    acls = [{ action = "accept", src = ["*"], dst = ["*:*"] }]
  })
}

# OAuth client used by the in-cluster Tailscale Kubernetes operator.
# The client ID and secret are exposed as sensitive outputs and consumed
# by `just seal-tailscale-oauth` to generate the operator-oauth SealedSecret.
resource "tailscale_oauth_client" "operator" {
  description = "k3s tailscale-operator"
  scopes      = ["devices:core", "auth_keys"]
  tags        = ["tag:k3s-operator"]
}
