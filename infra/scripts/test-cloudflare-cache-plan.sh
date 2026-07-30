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
expected_expression='(http.host eq "arunanshu.dev" and http.request.uri.path eq "/" and http.request.method in {"GET" "HEAD"} and not has_key(http.request.headers, "rsc") and not has_key(http.request.uri.args, "_rsc"))'

plan_json="$(
  tofu -chdir="${repository_root}/infra" show -json "${plan_path}"
)"

if ! jq -e --arg expected_expression "${expected_expression}" '
  [
    .planned_values.root_module.resources[]
    | select(.address == "cloudflare_ruleset.cache_rules")
    | .values.rules[]
    | select(.description == "Edge-cache arunanshu.dev home HTML")
  ] as $home_rules
  | ($home_rules | length) == 1
    and ($home_rules[0].enabled == true)
    and ($home_rules[0].action == "set_cache_settings")
    and ($home_rules[0].expression == $expected_expression)
    and ($home_rules[0].action_parameters.cache == true)
    and ($home_rules[0].action_parameters.edge_ttl.mode == "bypass_by_default")
    and ($home_rules[0].action_parameters.browser_ttl.mode == "respect_origin")
    and (
      [
        $home_rules[0].action_parameters
        | to_entries[]
        | select(.value != null)
        | .key
      ]
      | sort
    ) == ["browser_ttl", "cache", "edge_ttl"]
    and (
      [
        $home_rules[0].action_parameters.browser_ttl
        | to_entries[]
        | select(.value != null)
        | .key
      ]
      | sort
    ) == ["mode"]
    and (
      [
        $home_rules[0].action_parameters.edge_ttl
        | to_entries[]
        | select(.value != null)
        | .key
      ]
      | sort
    ) == ["mode"]
' <<<"${plan_json}" >/dev/null; then
  printf 'home document cache plan does not match the safety policy\n' >&2
  exit 1
fi

printf 'home document cache plan is safe\n'
