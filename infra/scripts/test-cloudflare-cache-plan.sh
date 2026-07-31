#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  printf 'usage: %s <saved-plan>\n' "$0" >&2
  exit 2
fi

repository_root="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1
  pwd -P
)"
plan_path="$1"
expected_expression='(http.host eq "arunanshu.dev" and http.request.method in {"GET" "HEAD"} and not starts_with(http.request.uri.path, "/api/") and not starts_with(http.request.uri.path, "/rpc/") and not (has_key(http.request.headers, "rsc") and not has_key(http.request.uri.args, "_rsc")))'
expected_description='Edge-cache arunanshu.dev when Next.js Cache-Control allows'
grafana_description='Edge-cache Grafana hashed JS/CSS bundles (/public/build/)'

plan_json="$(
  tofu -chdir="${repository_root}/infra" show -json "${plan_path}"
)"

if ! jq -e \
  --arg expected_expression "${expected_expression}" \
  --arg expected_description "${expected_description}" \
  --arg grafana_description "${grafana_description}" \
  '
  [
    .planned_values.root_module.resources[]
    | select(.address == "cloudflare_ruleset.cache_rules")
    | .values.rules[]
  ] as $rules
  | (
      [
        $rules[]
        | select(.description == $expected_description)
      ]
    ) as $doc_rules
  | (
      [
        $rules[]
        | select(.description == $grafana_description)
      ]
    ) as $grafana_rules
  | ($doc_rules | length) == 1
    and ($grafana_rules | length) == 1
    and ($doc_rules[0].enabled == true)
    and ($doc_rules[0].action == "set_cache_settings")
    and ($doc_rules[0].expression == $expected_expression)
    and ($doc_rules[0].action_parameters.cache == true)
    and ($doc_rules[0].action_parameters.edge_ttl.mode == "bypass_by_default")
    and ($doc_rules[0].action_parameters.browser_ttl.mode == "respect_origin")
    and (
      [
        $doc_rules[0].action_parameters
        | to_entries[]
        | select(.value != null)
        | .key
      ]
      | sort
    ) == ["browser_ttl", "cache", "edge_ttl"]
    and (
      [
        $doc_rules[0].action_parameters.browser_ttl
        | to_entries[]
        | select(.value != null)
        | .key
      ]
      | sort
    ) == ["mode"]
    and (
      [
        $doc_rules[0].action_parameters.edge_ttl
        | to_entries[]
        | select(.value != null)
        | .key
      ]
      | sort
    ) == ["mode"]
    and ($grafana_rules[0].enabled == true)
    and ($grafana_rules[0].action_parameters.cache == true)
' <<<"${plan_json}" >/dev/null; then
  printf 'arunanshu.dev origin-driven cache plan does not match the safety policy\n' >&2
  exit 1
fi

printf 'arunanshu.dev origin-driven cache plan is safe\n'
