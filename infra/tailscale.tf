provider "tailscale" {
  api_key = var.tailscale_api_key
  tailnet = var.tailscale_tailnet
}

# Manage the full tailnet ACL policy.
# tag:k3s-operator  — assigned to the OAuth client itself
# tag:k8s-operator  — assigned by the operator to devices it registers (operator's default)
resource "tailscale_acl" "main" {
  overwrite_existing_content = true

  acl = jsonencode({
    tagOwners = {
      "tag:k3s-operator" = ["autogroup:admin"]
      "tag:k8s-operator" = []
      "tag:k8s"          = ["tag:k8s-operator"]
    }
    acls = [{ action = "accept", src = ["*"], dst = ["*:*"] }]
  })
}

# OAuth client used by the in-cluster Tailscale Kubernetes operator.
# The client ID and secret are exposed as sensitive outputs and consumed
# by `just seal-tailscale-oauth` to generate the operator-oauth SealedSecret.
resource "tailscale_oauth_client" "operator" {
  description = "k3s tailscale-operator"
  scopes      = ["devices:core", "auth_keys", "services"]
  tags        = ["tag:k8s-operator"]

  depends_on = [tailscale_acl.main]
}
