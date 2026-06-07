# Public bypass for the blog's www subdomain — no auth required.
# The wildcard *.arunanshu.dev policy below would otherwise gate www.arunanshu.dev
# with email OTP since wildcard Access apps match all subdomains.
# Cloudflare evaluates the most specific hostname first, so this bypass wins.
resource "cloudflare_zero_trust_access_application" "www_bypass" {
  account_id       = var.cloudflare_account_id
  name             = "www.arunanshu.dev — public bypass"
  domain           = "www.arunanshu.dev"
  type             = "self_hosted"
  session_duration = "24h"

  policies = [
    {
      name       = "bypass"
      decision   = "bypass"
      precedence = 1
      include    = [{ everyone = {} }]
    },
  ]
}

# Cloudflare Access — single wildcard app gates all *.arunanshu.dev traffic.
# New services only need an HTTPRoute; no Terraform change required unless
# per-app access control is needed (different users, different session length).
# Auth: OTP email to owner_email. No IdP configured.
resource "cloudflare_zero_trust_access_application" "wildcard" {
  account_id            = var.cloudflare_account_id
  name                  = "*.arunanshu.dev"
  domain                = "*.arunanshu.dev"
  type                  = "self_hosted"
  session_duration      = "24h"
  enable_binding_cookie = true

  policies = [
    {
      name       = "allow-owner"
      decision   = "allow"
      precedence = 1
      include    = [{ email = { email = var.owner_email } }]
    },
  ]
}
