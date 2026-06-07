# Edge-cache content-hashed static bundles at the Cloudflare edge.
#
# Grafana (/public/build/): cold dashboard load is ~3.3MB of JS across ~34 files.
# The wildcard ZT app attaches CF_Authorization/Set-Cookie, which makes CF skip
# caching by default — override_origin bypasses that so bundles serve from the
# user's local edge (not Hetzner DE every time).
#
# www blog (/_next/static/) does NOT need a rule here: Next.js already sets
# Cache-Control: s-maxage=31536000 on these content-hashed paths, and the www
# bypass app (decision=bypass) adds no CF_Authorization cookie to poison the
# cache. Cloudflare respects s-maxage natively — adding override_origin at 7d
# would downgrade the TTL from 1 year to 7 days.
#
# Safety invariant: NEVER widen to /api, /d, /avatar, or any dynamic path —
# that would risk cache deception. Content-hashed paths only.
# Cost: $0 — Cache Rules are free (this is NOT Cache Reserve, the paid feature).
resource "cloudflare_ruleset" "grafana_static_cache" {
  zone_id = var.cloudflare_zone_id
  name    = "static-asset-cache"
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
          mode    = "override_origin"
          default = 604800 # 7d conservative; bump to 2592000 (30d) after checking Cache Analytics
        }
      }
    },
  ]
}
