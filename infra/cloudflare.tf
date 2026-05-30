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

# Bypass CF Access for the Prometheus SSE notifications endpoint.
# Cloudflare's Zero Trust tunnel cancels idle QUIC streams before the 200 OK
# reaches the browser — Prometheus holds this SSE connection open and only pushes
# events when a notification fires (config reload, rule error), so the stream
# appears stalled and Cloudflare resets it. X-Accel-Buffering: no does not help
# at the QUIC/ZT layer. Path-scoped bypass makes the stream go straight through.
# The endpoint emits only operational notifications — no metrics, no auth needed.
resource "cloudflare_zero_trust_access_application" "prometheus_sse_bypass" {
  account_id            = var.cloudflare_account_id
  name                  = "prometheus-notifications-live-bypass"
  domain                = "prometheus.arunanshu.dev/api/v1/notifications/live"
  type                  = "self_hosted"
  session_duration      = "24h"
  enable_binding_cookie = false

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

# Retrieve the tunnel token — used to authenticate cloudflared with Cloudflare's edge.
# Output via `just seal-cloudflared-token` to produce the SealedSecret.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "main" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.main.id
}

resource "cloudflare_r2_bucket" "etcd_snapshots" {
  account_id = var.cloudflare_account_id
  name       = "arunanshu-etcd-snapshots"
}

resource "cloudflare_r2_bucket_lifecycle" "etcd_snapshots" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.etcd_snapshots.name

  rules = [
    {
      id      = "expire-etcd-snapshots-after-45-days"
      enabled = true
      conditions = {
        prefix = ""
      }
      delete_objects_transition = {
        condition = {
          type    = "Age"
          max_age = 3888000
        }
      }
      abort_multipart_uploads_transition = {
        condition = {
          type    = "Age"
          max_age = 604800
        }
      }
    }
  ]
}

resource "cloudflare_r2_bucket" "velero_backups" {
  account_id = var.cloudflare_account_id
  name       = "arunanshu-velero-backups"
}

resource "cloudflare_r2_bucket_lifecycle" "velero_backups" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.velero_backups.name

  rules = [
    {
      id      = "expire-velero-backups-after-45-days"
      enabled = true
      conditions = {
        prefix = ""
      }
      delete_objects_transition = {
        condition = {
          type    = "Age"
          max_age = 3888000
        }
      }
      abort_multipart_uploads_transition = {
        condition = {
          type    = "Age"
          max_age = 604800
        }
      }
    }
  ]
}
