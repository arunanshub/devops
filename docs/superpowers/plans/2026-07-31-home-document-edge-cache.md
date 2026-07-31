# Home Document Edge Cache Implementation Plan

> **Superseded (2026-07-31):** Replaced by a **host-wide** origin-driven Cache Rule (all apex paths, Next.js headers as authority, RSC excluded) plus an optional Argo PostSync host purge Job. See `infra/cloudflare_cache.tf` and `kubernetes/base/apps/arunanshu-dev/resources/purge-cache-job.yaml`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal (historical):** Cache only the Next.js HTML response for `https://arunanshu.dev/` at Cloudflare while all RSC and uncacheable responses stay outside the edge cache.

**Architecture:** Add one rule to the existing zone-level `http_request_cache_settings` ruleset. The request expression excludes the `rsc` header and every `_rsc` query parameter form. `bypass_by_default` makes the origin `Cache-Control` header the cache authority.

**Tech Stack:** OpenTofu 1.12.4, Cloudflare provider 5.22.0, Cloudflare Cache Rules, Bash, and `jq`.

## Global Constraints

- Match only host `arunanshu.dev` and path `/`.
- Match only `GET` and `HEAD`.
- Exclude requests that contain the `rsc` header.
- Exclude requests that contain the `_rsc` query parameter, including bare `?_rsc`.
- Set `cache = true`.
- Set only `edge_ttl.mode = "bypass_by_default"`.
- Set only `browser_ttl.mode = "respect_origin"` to prevent the zone default from adding `max-age=14400`.
- Do not add a custom cache key, browser TTL value, origin TTL override, response-header rewrite, or cookie removal.
- Do not cache RSC responses.
- Do not change the Next.js application, Traefik, cloudflared, or Kubernetes.

---

### Task 1: Add the home HTML Cache Rule

**Files:**

- Create: `infra/scripts/test-cloudflare-cache-plan.sh`
- Modify: `infra/cloudflare_cache.tf`
- Reference: `docs/specs/2026-07-31-nextjs-kubernetes-self-hosting-hardening-design.md`

**Interfaces:**

- Consumes: OpenTofu plan JSON from `tofu show -json`.
- Produces: A Cloudflare Cache Rule with the exact safe match expression and origin-controlled TTL behavior.

- [ ] **Step 1: Write the failing plan assertion**

Create `infra/scripts/test-cloudflare-cache-plan.sh`. The script must find `cloudflare_ruleset.cache_rules` in an OpenTofu plan. It must require exactly one enabled rule with this expression:

```text
(http.host eq "arunanshu.dev" and http.request.uri.path eq "/" and http.request.method in {"GET" "HEAD"} and not has_key(http.request.headers, "rsc") and not has_key(http.request.uri.args, "_rsc"))
```

It must also require:

```text
action = "set_cache_settings"
cache = true
edge_ttl.mode = "bypass_by_default"
```

It must require `browser_ttl.mode = "respect_origin"`. It must reject a home rule that sets `cache_key`, `browser_ttl.default`, `origin_error_page_passthru`, `respect_strong_etags`, or an `edge_ttl.default` value.

- [ ] **Step 2: Run the assertion and confirm the red result**

Run:

```bash
cd infra
devbox run -- sops exec-env secrets.yaml \
  'tofu plan -input=false -no-color -out=/tmp/arunanshu-home-cache-red.tfplan'
cd ..
devbox run -- sops exec-env infra/secrets.yaml \
  './infra/scripts/test-cloudflare-cache-plan.sh /tmp/arunanshu-home-cache-red.tfplan'
```

Expected: the plan command succeeds and the assertion fails because the home rule does not exist.

- [ ] **Step 3: Add the minimal Cloudflare rule**

Add this rule after the Grafana rule in `infra/cloudflare_cache.tf`:

```hcl
{
  description = "Edge-cache arunanshu.dev home HTML"
  expression  = "(http.host eq \"arunanshu.dev\" and http.request.uri.path eq \"/\" and http.request.method in {\"GET\" \"HEAD\"} and not has_key(http.request.headers, \"rsc\") and not has_key(http.request.uri.args, \"_rsc\"))"
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
}
```

Replace the obsolete comment that says Cloudflare needs Enterprise to vary by request header. Explain that this change does not cache RSC because `_rsc` is not deployment-scoped.

- [ ] **Step 4: Run the assertion and confirm the green result**

Run:

```bash
cd infra
devbox run -- sops exec-env secrets.yaml \
  'tofu plan -input=false -no-color -out=/tmp/arunanshu-home-cache-green.tfplan'
cd ..
devbox run -- sops exec-env infra/secrets.yaml \
  './infra/scripts/test-cloudflare-cache-plan.sh /tmp/arunanshu-home-cache-green.tfplan'
```

Expected: both commands succeed. The plan adds one home cache rule. The assertion prints `home document cache plan is safe`.

- [ ] **Step 5: Run repository verification**

Run:

```bash
devbox run -- tofu fmt -check -recursive
devbox run -- sops exec-env infra/secrets.yaml \
  'tofu -chdir=infra validate -no-color'
git diff --check
```

Expected: all commands exit with status 0.

- [ ] **Step 6: Commit**

```bash
git add \
  docs/superpowers/plans/2026-07-31-home-document-edge-cache.md \
  infra/cloudflare_cache.tf \
  infra/scripts/test-cloudflare-cache-plan.sh
git commit -m "perf: cache the home document at Cloudflare"
```
