# Cloudflare edge caching for the arunanshu.dev zone.
#
# Cost: $0. Cache Rules and Tiered Cache are free on all plans (this is NOT
# Cache Reserve / Argo Smart Routing, the paid, per-GB-metered features — those
# are deliberately NOT used here so a traffic spike can never produce a bill).

# --- Smart Tiered Cache -------------------------------------------------------
# Free on all plans. Lower-tier edges (e.g. the Singapore colo that serves
# India) pull cache misses from a regional upper tier instead of crossing to the
# Hetzner EU origin every time. Pure win: shorter miss backhaul, higher global
# hit ratio, cannot poison or bypass anything. Only pays off on content that is
# actually cacheable — pair it with the page Cache Rule below.
resource "cloudflare_tiered_cache" "smart" {
  zone_id = var.cloudflare_zone_id
  value   = "on"
}

# --- Cache Rules (http_request_cache_settings phase) --------------------------
# A zone has exactly ONE entry-point ruleset per phase, so the Grafana static
# rule and the blog page rule below live in the same ruleset.
#
# Renamed from cloudflare_ruleset.grafana_static_cache (see moved block) now that
# it carries more than the Grafana rule.
resource "cloudflare_ruleset" "cache_rules" {
  zone_id = var.cloudflare_zone_id
  name    = "static-asset-cache" # kept as-is: changing the name forces a full ruleset replacement
  kind    = "zone"
  phase   = "http_request_cache_settings"

  rules = [
    # Grafana (/public/build/): cold dashboard load is ~3.3MB of JS across ~34
    # files. The wildcard ZT app attaches CF_Authorization/Set-Cookie, which
    # makes CF skip caching by default — override_origin bypasses that so bundles
    # serve from the user's local edge (not Hetzner DE every time).
    #
    # Safety invariant: NEVER widen to /api, /d, /avatar, or any dynamic path —
    # that would risk cache deception. Content-hashed paths only.
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

    # Cache only the home HTML response. bypass_by_default follows the
    # Cache-Control policy from Next.js. A future dynamic response marked
    # private, no-store, or no-cache therefore bypasses the Cloudflare cache.
    #
    # RSC stays dynamic. Its _rsc hash does not include the deployment id, and
    # Next.js cannot validate an RSC request when Cloudflare serves a cache hit.
    {
      description = "Edge-cache arunanshu.dev home HTML"
      expression  = "(http.host eq \"arunanshu.dev\" and http.request.uri.path eq \"/\" and http.request.method in {\"GET\" \"HEAD\"} and not has_key(http.request.headers, \"rsc\") and not has_key(http.request.uri.args, \"_rsc\"))"
      action      = "set_cache_settings"
      enabled     = true
      action_parameters = {
        cache = true
        edge_ttl = {
          mode = "bypass_by_default"
        }
      }
    },
  ]
}

moved {
  from = cloudflare_ruleset.grafana_static_cache
  to   = cloudflare_ruleset.cache_rules
}
