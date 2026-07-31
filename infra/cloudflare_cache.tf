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
# rule and the arunanshu.dev document rule live in the same ruleset.
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

    # Host-wide cache eligibility for arunanshu.dev. Cloudflare does not cache
    # HTML or text/x-component by default even when Next.js sends a shared
    # Cache-Control policy. This rule only makes responses *eligible*;
    # edge_ttl.mode = bypass_by_default keeps Next.js as the policy authority:
    # s-maxage / public → store; private / no-store / missing → bypass.
    #
    # No path allowlist: new public routes inherit edge caching from origin
    # headers. Defense-in-depth excludes /api and /rpc.
    #
    # RSC flights for static / use-cache routes send the same s-maxage as HTML.
    # Next.js keys variants via the _rsc query parameter (CDN cache key must
    # include the query string — Cloudflare default does). Include those
    # requests so soft navigation can HIT the edge.
    #
    # Exclude only: rsc header WITHOUT _rsc. Those requests return 307 to add
    # _rsc on the *document* URL; caching that under /path would poison HTML.
    # Deploy-time host purge (PostSync Job) clears HTML + all _rsc variants.
    {
      description = "Edge-cache arunanshu.dev when Next.js Cache-Control allows"
      expression  = "(http.host eq \"arunanshu.dev\" and http.request.method in {\"GET\" \"HEAD\"} and not starts_with(http.request.uri.path, \"/api/\") and not starts_with(http.request.uri.path, \"/rpc/\") and not (has_key(http.request.headers, \"rsc\") and not has_key(http.request.uri.args, \"_rsc\")))"
      action      = "set_cache_settings"
      enabled     = true
      action_parameters = {
        cache = true
        browser_ttl = {
          mode = "respect_origin"
        }
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
