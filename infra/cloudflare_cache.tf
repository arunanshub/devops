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
# A zone has exactly ONE entry-point ruleset per phase, so the zone-wide document
# rule and the Grafana static rule live in the same ruleset. Order matters.
#
# Renamed from cloudflare_ruleset.grafana_static_cache (see moved block) now that
# it carries more than the Grafana rule.
resource "cloudflare_ruleset" "cache_rules" {
  zone_id = var.cloudflare_zone_id
  name    = "static-asset-cache" # kept as-is: changing the name forces a full ruleset replacement
  kind    = "zone"
  phase   = "http_request_cache_settings"

  rules = [
    # Zone-wide eligibility. edge_ttl.bypass_by_default keeps the origin as the
    # policy authority: s-maxage / public → store; private / no-store → bypass.
    #
    # No host or path allowlist — a new subdomain needs no change here. Anything
    # that must not be cached simply says so in its own Cache-Control, and
    # Access-gated hosts bypass anyway (Set-Cookie without an edge_ttl override).
    # Defense-in-depth still excludes /api and /rpc.
    #
    # RSC parity: the rsc header and _rsc query parameter must be both present or
    # both absent, or the two representations share a cache key.
    {
      description = "Edge-cache any origin on this zone when its Cache-Control allows"
      expression  = "(http.request.method in {\"GET\" \"HEAD\"} and not starts_with(http.request.uri.path, \"/api/\") and not starts_with(http.request.uri.path, \"/rpc/\") and not (has_key(http.request.headers, \"rsc\") and not has_key(http.request.uri.args, \"_rsc\")) and not (has_key(http.request.uri.args, \"_rsc\") and not has_key(http.request.headers, \"rsc\")))"
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

    # Grafana (/public/build/): ~3.3MB of hashed JS on a cold load. The ZT app
    # attaches Set-Cookie, so only override_origin gets these cached.
    #
    # MUST stay last: within a phase the last matching rule wins, so this has to
    # follow the zone-wide rule above to keep its TTL.
    #
    # Safety invariant: NEVER widen to /api, /d, /avatar or any dynamic path —
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
  ]
}

moved {
  from = cloudflare_ruleset.grafana_static_cache
  to   = cloudflare_ruleset.cache_rules
}
