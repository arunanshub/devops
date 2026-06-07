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

# Retrieve the tunnel token — used to authenticate cloudflared with Cloudflare's edge.
# Output via `just seal-cloudflared-token` to produce the SealedSecret.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "main" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.main.id
}

# Edge-cache Grafana's static frontend bundles at the Cloudflare edge.
#
# Why: grafana.arunanshu.dev is reached from India via a CF edge ~76-100ms away,
# with the origin (Grafana) in Hetzner DE behind the cloudflared tunnel. A cold
# dashboard load pulls ~3.3MB of JS across ~34 files all the way from DE on every
# visit, because the wildcard Cloudflare Access app attaches CF_Authorization /
# Set-Cookie, and CF's default cache skips responses with Set-Cookie or
# Cache-Control: private/no-store. mode=override_origin ignores those and makes
# the bundles cacheable, so they serve from the user's local edge instead.
#
# Safety: scoped STRICTLY to /public/build/ — these files are content-hashed
# (e.g. app.1e0deb6b.js), identical for every Grafana user (open-source frontend),
# and contain no secrets or per-user data. A Grafana upgrade changes the hash, so
# the cache self-invalidates. Access still gates the app: logged-in users pass the
# edge auth check, then get an edge cache hit (no tunnel/DE round trip). NEVER widen
# this to /api, /d, /avatar, etc. — that would risk web cache deception (serving one
# user's private response to another). Cost: $0 (Cache Rules are free; this is NOT
# Cache Reserve, which is the paid, R2-backed feature).
resource "cloudflare_ruleset" "grafana_static_cache" {
  zone_id = var.cloudflare_zone_id
  name    = "grafana-static-asset-cache"
  kind    = "zone"
  phase   = "http_request_cache_settings"

  rules = [
    {
      description = "Edge-cache Grafana hashed JS/CSS bundles (/public/build/)"
      expression  = "(http.host eq \"grafana.arunanshu.dev\" and starts_with(http.request.uri.path, \"/public/build/\"))"
      action      = "set_cache_settings"
      enabled     = true
      action_parameters = {
        cache = true
        edge_ttl = {
          # Hashed filenames make these safe to hold; 7d is conservative.
          # Bump toward a month once you've confirmed hit rate in Cache Analytics.
          mode    = "override_origin"
          default = 604800
        }
      }
    },
  ]
}

# 0-RTT Connection Resumption: lets returning clients send their first request
# inside the opening TLS1.3/QUIC handshake packet, saving ~1 RTT (~80ms from .in)
# on every resumed connection. Free, all plans. Safe: Cloudflare restricts 0-RTT
# early data to idempotent GETs (early data is replayable), which is what Grafana's
# read path is. Zone-wide (affects all *.arunanshu.dev), not Grafana-specific.
resource "cloudflare_zone_setting" "zero_rtt" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "0rtt"
  value      = "on"
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
