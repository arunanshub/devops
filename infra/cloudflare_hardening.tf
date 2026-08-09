# --------------------------------- Security ---------------------------------

# Bot Fight Mode: challenges cloud-provider bots and headless browsers.
# AI bots (GPTBot, ClaudeBot, etc.) are allowed at the edge — they're polite
# crawlers and CF serves them cached content, so the origin sees negligible load.
# Requires "Bot Management" permission on the API token.
#
# The two AI settings have two different jobs:
#   - is_robots_txt_managed states a preference. It asks known AI trainers to
#     stay away. Compliance is voluntary.
#   - ai_bots_protection enforces the preference. It stays "disabled". The edge
#     serves AI bots from the cache. The origin cost is near zero.
resource "cloudflare_bot_management" "main" {
  zone_id            = var.cloudflare_zone_id
  fight_mode         = true
  enable_js          = true
  ai_bots_protection = "disabled"

  # Managed robots.txt. Cloudflare generates a block of Content-Signal
  # directives (search=yes, ai-train=no, use=reference). The block also holds a
  # Disallow rule for each known AI crawler. Cloudflare prepends the block to
  # the robots.txt that Next.js serves.
  #
  # Keep this field declared. The provider sends a full PUT. A dashboard toggle
  # with no matching line here plans back to false on the next apply.
  #
  # cf_robots_variant stays unset. That setting applies only when this one is
  # false.
  is_robots_txt_managed = true
}

# HSTS: browsers cache "HTTPS only" for 1 year zone-wide; nosniff adds
# X-Content-Type-Options. No preload — preloading is hard to undo.
resource "cloudflare_zone_setting" "hsts" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "security_header"
  value = {
    strict_transport_security = {
      enabled            = true
      include_subdomains = true
      max_age            = 31536000
      nosniff            = true
      preload            = false
    }
  }
}

resource "cloudflare_zone_setting" "min_tls_version" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "min_tls_version"
  value      = "1.2"
}

# tls_1_3 is intentionally omitted — enabling zero_rtt (above) sets the internal
# value to "zrt" (TLS1.3 + 0-RTT), which conflicts with value="on" every plan.
# 0-RTT requires TLS 1.3, so zero_rtt=on already implies TLS 1.3 is active.

# Redirect bare http:// requests to https:// at the edge.
resource "cloudflare_zone_setting" "always_use_https" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "always_use_https"
  value      = "on"
}

# Add best-practice response headers (X-Frame-Options, X-XSS-Protection,
# X-Content-Type-Options, Referrer-Policy) and strip X-Powered-By.
resource "cloudflare_managed_transforms" "main" {
  zone_id = var.cloudflare_zone_id

  managed_request_headers = []
  managed_response_headers = [
    { id = "add_security_headers", enabled = true },
    { id = "remove_x-powered-by_header", enabled = true },
  ]
}

# -------------------------------- Performance --------------------------------

# Brotli: CF re-compresses origin responses with brotli for supporting browsers,
# gzip for others. Origin (Next.js) has compress:false so CF owns this entirely.
resource "cloudflare_zone_setting" "brotli" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "brotli"
  value      = "on"
}

# Advertise Cloudflare edge IPv6 addresses for all proxied hostnames. The
# cloudflared origin path is independent and does not need inbound IPv6.
resource "cloudflare_zone_setting" "ipv6" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "ipv6"
  value      = "on"
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

# HTTP/3 (QUIC): browsers use QUIC transport by default when HTTP/3 is advertised,
# eliminating head-of-line blocking. Complements 0-RTT above.
resource "cloudflare_zone_setting" "http3" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "http3"
  value      = "on"
}

# 103 Early Hints: Cloudflare sends preload/preconnect hints to browsers while
# the origin is still generating the response, letting sub-resources start
# fetching sooner. Particularly helpful for the blog and Grafana initial load.
resource "cloudflare_zone_setting" "early_hints" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "early_hints"
  value      = "on"
}
