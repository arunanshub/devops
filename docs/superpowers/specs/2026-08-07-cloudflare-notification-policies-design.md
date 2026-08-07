# Cloudflare Notification Policies

## Goal

Manage the relevant Cloudflare reliability and security email alerts in OpenTofu so dashboard-only settings do not drift.

## Design

- Add enabled notification policies for HTTP DDoS attacks, Universal SSL lifecycle events, and Cloudflare Tunnel health changes.
- Deliver each policy to `var.owner_email` through Cloudflare email notifications.
- Limit the tunnel policy to the managed tunnel ID. Keep the account-wide HTTP DDoS and Universal SSL policies unfiltered because Cloudflare exposes no filter options for them on this account.
- Keep the policies in a dedicated Cloudflare notifications file.

## Limits

Do not change cache rules, cache settings, or Next.js caching behavior. Do not change the temporary HTTP/2 tunnel override. Certificate Transparency monitoring is not managed because Cloudflare provider v5.22 does not expose a Terraform resource for it. Kubernetes alert rules are outside this Terraform-only change.

## Validation

Format the OpenTofu files, validate the configuration with the SOPS-backed provider environment, and inspect a saved plan. Do not apply the plan.
