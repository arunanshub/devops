#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
launcher="${script_dir}/run-in-cluster.sh"

rendered="$(env RUN_ID=test bash "${launcher}" --dry-run --smoke)"

configmap_script="$(yq -r 'select(.kind == "ConfigMap") | .data."test.js"' - <<<"${rendered}")"
job_image="$(yq -r 'select(.kind == "Job") | .spec.template.spec.containers[0].image' - <<<"${rendered}")"
target_url="$(yq -r 'select(.kind == "Job") | .spec.template.spec.containers[0].env[] | select(.name == "TARGET_URL") | .value' - <<<"${rendered}")"
method="$(yq -r 'select(.kind == "Job") | .spec.template.spec.containers[0].env[] | select(.name == "METHOD") | .value' - <<<"${rendered}")"
profile="$(yq -r 'select(.kind == "Job") | .spec.template.spec.containers[0].env[] | select(.name == "PROFILE") | .value' - <<<"${rendered}")"
token_mount="$(yq -r 'select(.kind == "Job") | .spec.template.spec.automountServiceAccountToken' - <<<"${rendered}")"
restart_policy="$(yq -r 'select(.kind == "Job") | .spec.template.spec.restartPolicy' - <<<"${rendered}")"
backoff_limit="$(yq -r 'select(.kind == "Job") | .spec.backoffLimit' - <<<"${rendered}")"
deadline="$(yq -r 'select(.kind == "Job") | .spec.activeDeadlineSeconds' - <<<"${rendered}")"

grep -q 'ramping-arrival-rate' <<<"${configmap_script}"
[[ "${job_image}" == "grafana/k6:2.1.0" ]]
[[ "${target_url}" == "http://traefik.traefik.svc.cluster.local/blog/next-server-actions-client-side-data-fetching" ]]
[[ "${method}" == "GET" ]]
[[ "${profile}" == "smoke" ]]
[[ "${token_mount}" == "false" ]]
[[ "${restart_policy}" == "Never" ]]
[[ "${backoff_limit}" == "0" ]]
[[ "${deadline}" == "480" ]]

grep -q 'app: arunanshu-dev' <<<"${rendered}"
grep -q 'state.terminated.exitCode' "${launcher}"
grep -q 'KEDA did not scale above the baseline' "${launcher}"
grep -q 'create -f -' "${launcher}"
