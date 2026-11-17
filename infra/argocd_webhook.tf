# --------------------------- Argo CD GitHub webhook ---------------------------
#
# GitHub POSTs push events to argocd-hook.arunanshu.dev/api/webhook, so Argo CD
# refreshes on merge instead of on its 3-minute poll. Polling stays on as the
# fallback for dropped deliveries.
#
# The UI host (argocd.arunanshu.dev) stays behind the wildcard Access OTP. The
# hook host is public, and four independent layers keep it narrow:
#   1. Cloudflare WAF (cloudflare_waf.tf): only GitHub's hook IPs, only
#      `POST /api/webhook`; everything else is blocked at the edge.
#   2. Cloudflare Access (cloudflare_access.tf): the bypass covers only the
#      /api/webhook path; any other path on the host still gets the OTP page.
#   3. Traefik (components/argocd-webhook): the HTTPRoute matches only
#      `POST /api/webhook` and is rate-limited.
#   4. Argo CD: drops any delivery whose X-Hub-Signature-256 HMAC does not match
#      webhook.github.secret.
#
# https://argo-cd.readthedocs.io/en/stable/operator-manual/webhook/
# https://docs.github.com/en/webhooks/using-webhooks/best-practices-for-using-webhooks

locals {
  argocd_webhook_host = "argocd-hook.arunanshu.dev"
  argocd_webhook_path = "/api/webhook"

  # GitHub's webhook source ranges (IPv4 and IPv6). GitHub changes these
  # occasionally and says to query the API instead of pinning, so every plan
  # re-reads them; a changed range shows up as a WAF rule diff.
  # https://docs.github.com/en/rest/meta/meta#get-github-meta-information
  github_hook_cidrs = jsondecode(data.http.github_meta.response_body).hooks
}

data "http" "github_meta" {
  url = "https://api.github.com/meta"

  request_headers = {
    Accept               = "application/vnd.github+json"
    X-GitHub-Api-Version = "2022-11-28"
  }

  retry {
    attempts = 2
  }

  lifecycle {
    # An empty list would render `ip.src in {}` and block every delivery; fail
    # the plan instead of shipping that.
    postcondition {
      condition     = self.status_code == 200 && length(jsondecode(self.response_body).hooks) > 0
      error_message = "GET https://api.github.com/meta did not return a non-empty `hooks` list."
    }
  }
}

# HMAC key shared by GitHub (signs) and Argo CD (verifies). Never printed: it
# goes from state straight into kubeseal (`just seal-argocd-webhook`) and the
# GitHub API (`just github-argocd-webhook`). Hex-safe so neither side needs
# quoting. Taint and re-run both recipes to rotate.
resource "random_password" "argocd_webhook" {
  length  = 64
  special = false
}
