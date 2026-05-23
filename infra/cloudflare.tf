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

# Cloudflare Access — identity gate for internal tools.
# Access apps are per-service; public services need no Access app and will flow
# through the wildcard tunnel directly. Default auth (no IdP configured) sends
# an OTP email to the declared address.
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

# Retrieve the tunnel token — used to authenticate cloudflared with Cloudflare's edge.
# Output via `just seal-cloudflared-token` to produce the SealedSecret.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "main" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.main.id
}
