provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Stable random secret — Terraform stores this in state and never regenerates it
# unless the resource is explicitly destroyed. Do not add keepers.
resource "random_bytes" "tunnel_secret" {
  length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "main" {
  account_id    = var.cloudflare_account_id
  name          = "k3s-cluster"
  config_src    = "cloudflare"
  tunnel_secret = random_bytes.tunnel_secret.base64
}

# Single wildcard rule routes all *.arunanshu.dev to Traefik.
# Traefik decides the final destination via HTTPRoutes — no Terraform change needed
# when adding new services. The catch-all at the end is required by cloudflared.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "main" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.main.id

  config = {
    ingress = [
      {
        # apex must precede the wildcard — cloudflared matches rules in order
        hostname = "arunanshu.dev"
        service  = "http://traefik.traefik.svc.cluster.local:80"
      },
      {
        hostname = "*.arunanshu.dev"
        service  = "http://traefik.traefik.svc.cluster.local:80"
      },
      {
        # catch-all — cloudflared rejects configs without this terminal rule
        service = "http_status:404"
      },
    ]
  }
}

# Single wildcard CNAME — proxied=true is mandatory. Without it, traffic bypasses
# Cloudflare Access entirely and hits the tunnel with no authentication layer.
resource "cloudflare_dns_record" "apex" {
  zone_id = var.cloudflare_zone_id
  name    = "@"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.main.id}.cfargotunnel.com"
  proxied = true
  comment = "Apex — arunanshu.dev routed via cloudflared to Traefik"
  ttl     = 1
}

resource "cloudflare_dns_record" "wildcard" {
  zone_id = var.cloudflare_zone_id
  name    = "*"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.main.id}.cfargotunnel.com"
  proxied = true
  comment = "Wildcard — all *.arunanshu.dev routed via cloudflared to Traefik"
  ttl     = 1
}

# Cloudflare Access — identity gate for all tunnel traffic.
#
# Default-deny: the wildcard app below blocks every subdomain that does not
# have a more-specific Access application. Cloudflare resolves applications by
# specificity — an exact hostname (e.g. grafana.arunanshu.dev) always wins over
# *.arunanshu.dev. This means a new HTTPRoute is unreachable until a matching
# Access app is added and `just apply` is run.
#
# Auth method: OTP email sent to owner_email (no IdP configured). Session
# duration 24h on per-service apps; the wildcard deny has no session.
resource "cloudflare_zero_trust_access_application" "default_deny" {
  account_id = var.cloudflare_account_id
  name       = "Default Deny"
  domain     = "*.arunanshu.dev"
  type       = "self_hosted"

  policies = [
    {
      name       = "deny-all"
      decision   = "deny"
      precedence = 1
      include    = [{ everyone = {} }]
    },
  ]
}

resource "cloudflare_zero_trust_access_application" "grafana" {
  account_id       = var.cloudflare_account_id
  name             = "Grafana"
  domain           = "grafana.arunanshu.dev"
  type             = "self_hosted"
  session_duration = "24h"

  policies = [
    {
      name       = "allow-owner"
      decision   = "allow"
      precedence = 1
      include    = [{ email = { email = var.owner_email } }]
    },
  ]
}

resource "cloudflare_zero_trust_access_application" "argocd" {
  account_id       = var.cloudflare_account_id
  name             = "ArgoCD"
  domain           = "argocd.arunanshu.dev"
  type             = "self_hosted"
  session_duration = "24h"

  policies = [
    {
      name       = "allow-owner"
      decision   = "allow"
      precedence = 1
      include    = [{ email = { email = var.owner_email } }]
    },
  ]
}

resource "cloudflare_zero_trust_access_application" "traefik" {
  account_id       = var.cloudflare_account_id
  name             = "Traefik Dashboard"
  domain           = "traefik.arunanshu.dev"
  type             = "self_hosted"
  session_duration = "24h"

  policies = [
    {
      name       = "allow-owner"
      decision   = "allow"
      precedence = 1
      include    = [{ email = { email = var.owner_email } }]
    },
  ]
}

resource "cloudflare_zero_trust_access_application" "hubble" {
  account_id       = var.cloudflare_account_id
  name             = "Hubble UI"
  domain           = "hubble.arunanshu.dev"
  type             = "self_hosted"
  session_duration = "24h"

  policies = [
    {
      name       = "allow-owner"
      decision   = "allow"
      precedence = 1
      include    = [{ email = { email = var.owner_email } }]
    },
  ]
}

# Retrieve the tunnel token — used to authenticate cloudflared with Cloudflare's edge.
# Output via `just seal-cloudflared-token` to produce the SealedSecret.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "main" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.main.id
}
