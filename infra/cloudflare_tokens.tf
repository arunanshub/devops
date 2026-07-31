# Cloudflare account API tokens used by in-cluster Jobs (least privilege).
# Keep this file separate from zone Cache Rules / DNS / tunnel config so token
# lifecycle is obvious and does not mix with edge policy HCL.
#
# Parent TF_VAR_cloudflare_api_token must allow Account API Tokens:Edit.
# After apply: `just seal-cf-cache-purge` seals the sensitive output for Argo.

# Zone → Cache Purge only, scoped to arunanshu.dev. Consumed by the
# arunanshu-dev PostSync Job (kubernetes/.../purge-cache-job.yaml).
# Permission group id is Cloudflare's stable "Cache Purge" group.
resource "cloudflare_account_token" "cache_purge" {
  account_id = var.cloudflare_account_id
  name       = "arunanshu-dev-cache-purge"

  policies = [{
    effect = "allow"
    permission_groups = [{
      id = "e17beae8b8cb423a99b1730f21238bed" # Zone Cache Purge
    }]
    resources = jsonencode({
      "com.cloudflare.api.account.zone.${var.cloudflare_zone_id}" = "*"
    })
  }]
}
