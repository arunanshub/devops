# Argo CD GitHub webhook

GitHub POSTs push events to `https://argocd-hook.arunanshu.dev/api/webhook`, and Argo CD refreshes the matching Applications in seconds instead of waiting for the poll (`timeout.reconciliation` 120s + up to 60s jitter, left at the chart default). Polling stays on: a dropped or rejected delivery only costs the old latency.

The UI host `argocd.arunanshu.dev` is unchanged and stays behind the wildcard Access OTP.

## Layers

| Layer | Where | What it admits |
|-------|-------|----------------|
| Cloudflare WAF custom rule | `infra/cloudflare_waf.tf` | Only GitHub's `hooks` CIDRs (read from `api.github.com/meta` on every plan), only `POST /api/webhook` |
| Cloudflare Access bypass | `infra/cloudflare_access.tf` | Only the `/api/webhook` path; any other path on the host gets the OTP page |
| Traefik HTTPRoute + RateLimit | `kubernetes/components/argocd-webhook` | Only `POST /api/webhook` (anything else is a 404); 30/min, burst 30, per Traefik pod |
| Argo CD | `configs.secret.githubSecret` in both argocd values files | Only deliveries whose `X-Hub-Signature-256` HMAC matches; body capped at 5MB |

The HMAC secret lives in tofu state (`random_password.argocd_webhook`), is sealed into `argocd-webhook-github` (labelled `app.kubernetes.io/part-of: argocd`, which Argo CD requires for a `$secret:key` reference), and is sent to GitHub through the API. It is never printed.

## First rollout

1. **Check for dashboard WAF rules.** `cloudflare_ruleset.zone_custom_firewall` takes over the zone's custom-rules entry point. If Security → WAF → Custom rules lists anything, import it into `infra/cloudflare_waf.tf` first (`cf-terraforming`), or the apply fails or replaces it.
2. `just infra-apply` — creates the secret, the WAF rule and the Access bypass.
3. `just seal-argocd-webhook` — writes `kubernetes/components/argocd-webhook/resources/github-secret.sealedsecret.yaml`. Commit it; CI's manifest check fails until this file exists.
4. Merge. The `argocd-webhook` Application auto-syncs. The `argocd` Application does **not** (self-management is manual): sync it so `argocd-secret` gets `webhook.github.secret` and `argocd-cm` gets `webhook.maxPayloadSizeMB` (argocd-server rolls on the cm checksum). Check the live objects, not just "Synced".
5. `just github-argocd-webhook` — creates the hook (push events only) and prints its id. Running it twice creates a second hook.
6. Push a trivial commit and watch an Application refresh within seconds. GitHub → Settings → Webhooks → Recent Deliveries shows every attempt with the response.

## When a delivery fails

Read the response in Recent Deliveries first, then Cloudflare Security → Events.

| Response | Cause | Fix |
|----------|-------|-----|
| 403, Cloudflare block page, event source "Custom rules" | WAF lockdown | GitHub changed ranges: `just infra-plan` shows the diff, `just infra-apply` |
| 403 / challenge, event source "Bot fight mode" | Bot Fight Mode (`cloudflare_hardening.tf`) runs outside the Ruleset Engine; no custom rule can skip it | Add IP Access *allow* rules for the `hooks` CIDRs (Bot Fight Mode does not trigger when an IP Access rule matches first), or turn Bot Fight Mode off. Both are zone-wide trade-offs; decide deliberately |
| 302 to `cloudflareaccess.com` | Access bypass missing or not matching | Check the `argocd_webhook_bypass` app path |
| 404 from Traefik | Route mismatch | URL path or method wrong; check the hook URL |
| 429 | Traefik rate limit | Look for a redelivery storm or push loop before raising the limit |
| 4xx from Argo CD about the signature | Secret mismatch | Re-run step 3 and the rotation PATCH below |

Docs: <https://developers.cloudflare.com/waf/feature-interoperability/>, <https://developers.cloudflare.com/bots/get-started/bot-fight-mode/>

## Rotate the secret

1. From `infra/`: `sops exec-env secrets.yaml "tofu apply -replace=random_password.argocd_webhook"`.
2. `just seal-argocd-webhook`, commit, merge (the `$ref` re-resolves; no argocd sync needed).
3. Update GitHub's copy (hook id from step 5 above, or `gh api repos/arunanshub/devops/hooks --jq '.[] | [.id, .config.url]'`):

   ```bash
   just _tofu-output argocd_webhook_secret \
     | jq -Rn --arg url https://argocd-hook.arunanshu.dev/api/webhook -f infra/github-webhook.jq \
     | jq .config | gh api --method PATCH repos/arunanshub/devops/hooks/<id>/config --input -
   ```

The body carries the whole `config` (url, content type, TLS check, secret), so nothing depends on how the endpoint treats omitted fields: <https://docs.github.com/en/rest/repos/webhooks#update-a-webhook-configuration-for-a-repository>.

Between steps 2 and 3, deliveries fail the HMAC check and polling covers the gap.
