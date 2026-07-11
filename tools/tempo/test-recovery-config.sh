#!/usr/bin/env bash
set -euo pipefail

tempo_render="$(
  helm template tempo grafana-community/tempo \
    --version 2.2.3 \
    --namespace monitoring \
    --values kubernetes/base/monitoring/tempo/values.yaml
)"

tempo_request="$(yq -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "tempo") | .resources.requests.memory' - <<<"${tempo_render}")"
tempo_limit="$(yq -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "tempo") | .resources.limits.memory' - <<<"${tempo_render}")"
go_memlimit="$(yq -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "tempo") | .env[] | select(.name == "GOMEMLIMIT") | .value' - <<<"${tempo_render}")"

[[ "${tempo_request}" == "640Mi" ]]
[[ "${tempo_limit}" == "1Gi" ]]
[[ "${go_memlimit}" == "800MiB" ]]

vpa_file="kubernetes/components/monitoring-vpa/resources/vpa-tempo.yaml"
vpa_min_replicas="$(yq -r '.spec.updatePolicy.minReplicas' "${vpa_file}")"
vpa_controlled_values="$(yq -r '.spec.resourcePolicy.containerPolicies[0].controlledValues' "${vpa_file}")"
vpa_min_memory="$(yq -r '.spec.resourcePolicy.containerPolicies[0].minAllowed.memory' "${vpa_file}")"
vpa_max_memory="$(yq -r '.spec.resourcePolicy.containerPolicies[0].maxAllowed.memory' "${vpa_file}")"

[[ "${vpa_min_replicas}" == "1" ]]
[[ "${vpa_controlled_values}" == "RequestsAndLimits" ]]
[[ "${vpa_min_memory}" == "640Mi" ]]
[[ "${vpa_max_memory}" == "1Gi" ]]

app_render="$(kubectl kustomize kubernetes/base/apps/arunanshu-dev/resources)"
app_sampler="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "arunanshu-dev") | .env[] | select(.name == "OTEL_TRACES_SAMPLER") | .value' - <<<"${app_render}")"
app_sampling="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "arunanshu-dev") | .env[] | select(.name == "OTEL_TRACES_SAMPLER_ARG") | .value' - <<<"${app_render}")"
[[ "${app_sampler}" == "parentbased_traceidratio" ]]
[[ "${app_sampling}" == "0.05" ]]

traefik_render="$(
  helm template traefik traefik/traefik \
    --version 40.3.0 \
    --namespace traefik \
    --set metrics.prometheus.serviceMonitor.enabled=false \
    --values kubernetes/base/platform/traefik/values.yaml
)"
grep -q -- '--tracing.sampleRate=0.05' <<<"${traefik_render}"

traefik_scrape_interval="$(yq -r '.metrics.prometheus.serviceMonitor.interval' kubernetes/base/platform/traefik/values.yaml)"
[[ "${traefik_scrape_interval}" == "15s" ]]
