#!/usr/bin/env bash
# Structural gate: cache-purge token HCL lives only in cloudflare_tokens.tf.
# Resource address must stay cloudflare_account_token.cache_purge (state stable).
set -euo pipefail

repository_root="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1
  pwd -P
)"
infra="${repository_root}/infra"
tokens_file="${infra}/cloudflare_tokens.tf"
cache_file="${infra}/cloudflare_cache.tf"

if [[ ! -f "${tokens_file}" ]]; then
  printf 'missing %s\n' "${tokens_file}" >&2
  exit 1
fi

if ! grep -qE '^resource "cloudflare_account_token" "cache_purge"' "${tokens_file}"; then
  printf 'cloudflare_account_token.cache_purge must be defined in cloudflare_tokens.tf\n' >&2
  exit 1
fi

if grep -qE 'cloudflare_account_token' "${cache_file}"; then
  printf 'cloudflare_account_token must not appear in cloudflare_cache.tf\n' >&2
  exit 1
fi

# Exactly one token resource address in all .tf under infra/
count="$(
  grep -R --include='*.tf' -hE '^resource "cloudflare_account_token" "cache_purge"' "${infra}" \
    | wc -l | tr -d ' '
)"
if [[ "${count}" != "1" ]]; then
  printf 'expected exactly one cloudflare_account_token.cache_purge definition, found %s\n' "${count}" >&2
  exit 1
fi

# Seal recipe must read the tofu output for the token
if ! grep -q 'cache_purge_token' "${repository_root}/Justfile"; then
  printf 'Justfile must reference cache_purge_token for seal-cf-cache-purge\n' >&2
  exit 1
fi

if ! grep -q 'output "cache_purge_token"' "${infra}/outputs.tf"; then
  printf 'outputs.tf must export cache_purge_token\n' >&2
  exit 1
fi

printf 'cloudflare token layout is safe\n'

# Cross-check: document Cache Rule expression in HCL matches plan assertion script.
cache_tf="${infra}/cloudflare_cache.tf"
plan_script="${infra}/scripts/test-cloudflare-cache-plan.sh"
tf_expr="$(
  sed -n '/Edge-cache arunanshu.dev when Next.js Cache-Control allows/,/action_parameters/p' "${cache_tf}" \
    | sed -n 's/.*expression[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' \
    | head -1 \
    | sed 's/\\"/"/g'
)"
script_expr="$(
  sed -n "s/^expected_expression='\(.*\)'/\1/p" "${plan_script}" | head -1
)"
if [[ -z "${tf_expr}" || -z "${script_expr}" || "${tf_expr}" != "${script_expr}" ]]; then
  printf 'Cache Rule expression mismatch between cloudflare_cache.tf and test-cloudflare-cache-plan.sh\n' >&2
  printf 'tf:     %s\n' "${tf_expr}" >&2
  printf 'script: %s\n' "${script_expr}" >&2
  exit 1
fi

printf 'cache rule expression matches plan assertion script\n'
