#!/usr/bin/env bash
set -euo pipefail

rendered="$(
  kubectl kustomize kubernetes/base/apps/arunanshu-dev/resources |
    yq '.' -
)"
manifest="$(yq 'select(.kind == "ScaledObject")' - <<<"${rendered}")"

value() {
  yq -r "$1" - <<<"${manifest}"
}

threshold="$(value '.spec.triggers[0].metadata.threshold')"
scale_up_window="$(value '.spec.advanced.horizontalPodAutoscalerConfig.behavior.scaleUp.stabilizationWindowSeconds')"
scale_down_window="$(value '.spec.advanced.horizontalPodAutoscalerConfig.behavior.scaleDown.stabilizationWindowSeconds')"
scale_up_percent="$(value '.spec.advanced.horizontalPodAutoscalerConfig.behavior.scaleUp.policies[0].value')"
scale_up_pods="$(value '.spec.advanced.horizontalPodAutoscalerConfig.behavior.scaleUp.policies[1].value')"

[[ "${threshold}" == "0.4" ]]
[[ "${scale_up_window}" == "0" ]]
[[ "${scale_down_window}" == "300" ]]
[[ "${scale_up_percent}" == "100" ]]
[[ "${scale_up_pods}" == "4" ]]

memory_limit="$(
  yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "arunanshu-dev") | .resources.limits.memory' - <<<"${rendered}"
)"
[[ "${memory_limit}" == "384Mi" ]]

app_deployment="$(
  yq 'select(.kind == "Deployment" and .metadata.name == "arunanshu-dev")' \
    - <<<"${rendered}"
)"
termination_grace="$(
  yq -r '.spec.template.spec.terminationGracePeriodSeconds' \
    - <<<"${app_deployment}"
)"
pre_stop_sleep="$(
  yq -r '.spec.template.spec.containers[] |
    select(.name == "arunanshu-dev") |
    .lifecycle.preStop.sleep.seconds' \
    - <<<"${app_deployment}"
)"
keep_alive_timeout="$(
  yq -r '.spec.template.spec.containers[] |
    select(.name == "arunanshu-dev") |
    .env[] |
    select(.name == "KEEP_ALIVE_TIMEOUT") |
    .value' \
    - <<<"${app_deployment}"
)"

[[ "${termination_grace}" == "60" ]]
[[ "${pre_stop_sleep}" == "5" ]]
[[ "${keep_alive_timeout}" == "95000" ]]
