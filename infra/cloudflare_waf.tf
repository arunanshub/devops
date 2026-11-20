# ------------------------------ WAF custom rules ------------------------------
#
# This resource is the zone's entry-point ruleset for the
# http_request_firewall_custom phase, and OpenTofu owns it whole: "Terraform
# assumes that it has complete control over account and zone rulesets."
# Dashboard-made custom rules must be imported here first (cf-terraforming), or
# the first apply fails or replaces them. Free plan: 5 custom rules per zone.
# https://developers.cloudflare.com/terraform/additional-configurations/waf-custom-rules/
# https://developers.cloudflare.com/waf/custom-rules/
#
# Known gap: Bot Fight Mode (cloudflare_hardening.tf) runs outside the Ruleset
# Engine, so no rule here can skip it. If it challenges GitHub's deliveries
# (Security > Events, or "Recent Deliveries" on the GitHub hook), see
# docs/runbooks/argocd-webhook.md.
# https://developers.cloudflare.com/waf/feature-interoperability/

resource "cloudflare_ruleset" "zone_custom_firewall" {
  zone_id     = var.cloudflare_zone_id
  name        = "Zone custom rules"
  description = "Entry point for http_request_firewall_custom; managed by OpenTofu."
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules = [
    {
      ref         = "argocd_webhook_lockdown"
      description = "argocd-hook: allow only GitHub hook IPs sending POST ${local.argocd_webhook_path}"
      action      = "block"
      enabled     = true
      expression = join(" ", [
        "(http.host eq \"${local.argocd_webhook_host}\" and (",
        "not ip.src in {${join(" ", local.github_hook_cidrs)}}",
        "or http.request.method ne \"POST\"",
        "or http.request.uri.path ne \"${local.argocd_webhook_path}\"",
        "))",
      ])
    },
  ]
}
