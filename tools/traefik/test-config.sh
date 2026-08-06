#!/usr/bin/env bash
set -euo pipefail

assert_equal() {
  local expected="$1"
  local actual="$2"

  if [[ "${actual}" != "${expected}" ]]; then
    printf 'expected %q, got %q\n' "${expected}" "${actual}" >&2
    return 1
  fi
}

application="kubernetes/base/platform/traefik/application.yaml"
values="kubernetes/base/platform/traefik/values.yaml"
scaled_object="kubernetes/components/traefik-scaling/resources/scaledobject.yaml"
network_policy="kubernetes/components/network-policies/resources/traefik-netpol.yaml"
argocd_values="kubernetes/base/infra/argocd/values.yaml"
argocd_bootstrap_values="kubernetes/bootstrap/values/argocd.yaml"
cluster_alerts="kubernetes/base/monitoring/cluster-alerts/resources/prometheusrule.yaml"

chart_version="$(
  yq -r '.spec.sources[] | select(.chart == "traefik") | .targetRevision' \
    "${application}"
)"
assert_equal "41.1.0" "${chart_version}"

rendered="$(
  helm template traefik traefik/traefik \
    --version "${chart_version}" \
    --namespace traefik \
    --api-versions monitoring.coreos.com/v1 \
    --values "${values}"
)"

deployment="$(
  yq 'select(.kind == "Deployment" and .metadata.name == "traefik")' \
    <<<"${rendered}"
)"

replicas_present="$(yq -r '.spec | has("replicas")' <<<"${deployment}")"
assert_equal "false" "${replicas_present}"
go_mem_limit="$(
  yq -r '.spec.template.spec.containers[0].env[] |
    select(.name == "GOMEMLIMIT") | .value' <<<"${deployment}"
)"
assert_equal "921MiB" "${go_mem_limit}"
topology_behavior="$(
  yq -r '.spec.template.spec.topologySpreadConstraints[] |
    select(.topologyKey == "kubernetes.io/hostname") | .whenUnsatisfiable' \
    <<<"${deployment}"
)"
assert_equal "DoNotSchedule" "${topology_behavior}"
termination_grace="$(
  yq -r '.spec.template.spec.terminationGracePeriodSeconds' \
    <<<"${deployment}"
)"
assert_equal "60" "${termination_grace}"
request_accept_grace_count="$(
  yq '[.spec.template.spec.containers[] |
    select(.name == "traefik") |
    .args[] |
    select(. == "--entryPoints.web.transport.lifeCycle.requestAcceptGraceTimeout=5s")] |
    length' <<<"${deployment}"
)"
assert_equal "1" "${request_accept_grace_count}"
active_request_grace_count="$(
  yq '[.spec.template.spec.containers[] |
    select(.name == "traefik") |
    .args[] |
    select(. == "--entryPoints.web.transport.lifeCycle.graceTimeOut=50s")] |
    length' <<<"${deployment}"
)"
assert_equal "1" "${active_request_grace_count}"
version_check_disabled_count="$(
  yq '[.spec.template.spec.containers[] |
    select(.name == "traefik") |
    .args[] |
    select(. == "--global.checkNewVersion=false")] |
    length' <<<"${deployment}"
)"
assert_equal "1" "${version_check_disabled_count}"
anonymous_usage_enabled_count="$(
  yq '[.spec.template.spec.containers[] |
    select(.name == "traefik") |
    .args[] |
    select(. == "--global.sendAnonymousUsage")] |
    length' <<<"${deployment}"
)"
assert_equal "0" "${anonymous_usage_enabled_count}"

grep -q -- '--accesslog=true' <<<"${rendered}"
grep -q -- '--accesslog.format=json' <<<"${rendered}"
grep -q -- '--accesslog.filters.statuscodes=400-599' <<<"${rendered}"
if grep -q -- '--providers.kubernetesingress' <<<"${rendered}"; then
  printf 'the unused Kubernetes Ingress provider is enabled\n' >&2
  exit 1
fi
ingress_class="$(
  yq -r 'select(.kind == "IngressClass") | .metadata.name' <<<"${rendered}"
)"
assert_equal "" "${ingress_class}"
old_logs_key="$(yq -r 'has("logs")' "${values}")"
assert_equal "false" "${old_logs_key}"

fallback_behavior="$(yq -r '.spec.fallback.behavior' "${scaled_object}")"
assert_equal "currentReplicasIfHigher" "${fallback_behavior}"
cooldown_present="$(yq -r '.spec | has("cooldownPeriod")' "${scaled_object}")"
assert_equal "false" "${cooldown_present}"

policy_name="$(yq -r '.metadata.name' "${network_policy}")"
assert_equal "traefik" "${policy_name}"
policy_namespace="$(yq -r '.metadata.namespace' "${network_policy}")"
assert_equal "traefik" "${policy_namespace}"
policy_app_label="$(
  yq -r '.spec.endpointSelector.matchLabels."app.kubernetes.io/name"' \
    "${network_policy}"
)"
assert_equal "traefik" "${policy_app_label}"
for port in 8000 8080 9100; do
  grep -q "port: \"${port}\"" "${network_policy}"
done
grep -q 'k8s:io.kubernetes.pod.namespace: cloudflared' "${network_policy}"
grep -q 'k8s:io.kubernetes.pod.namespace: arunanshu-dev' "${network_policy}"
grep -q 'k8s:io.kubernetes.pod.namespace: monitoring' "${network_policy}"
grep -q 'app.kubernetes.io/name: k6' "${network_policy}"
grep -q 'fromEntities:' "${network_policy}"
grep -q -- '- host' "${network_policy}"
mixed_source_rules="$(
  yq '[.spec.ingress[] |
    select(has("fromEndpoints") and has("fromEntities"))] | length' \
    "${network_policy}"
)"
assert_equal "0" "${mixed_source_rules}"
api_server_egress_port="$(
  yq -r '.spec.egress[] |
    select(.toEntities[]? == "kube-apiserver") |
    .toPorts[].ports[] |
    select(.port == "6443" and .protocol == "TCP") | .port' \
    "${network_policy}"
)"
assert_equal "6443" "${api_server_egress_port}"
api_load_balancer_cidr_rules="$(
  yq '[.spec.egress[] |
    select(.toCIDR[]? == "10.0.0.100/32") |
    select(.toPorts[].ports[]? | .port == "6443" and .protocol == "TCP")] |
    length' "${network_policy}"
)"
assert_equal "0" "${api_load_balancer_cidr_rules}"

argocd_values_json="$(yq -o=json '.' "${argocd_values}")"
argocd_bootstrap_values_json="$(yq -o=json '.' "${argocd_bootstrap_values}")"
assert_equal "${argocd_values_json}" "${argocd_bootstrap_values_json}"
for file in "${argocd_values}" "${argocd_bootstrap_values}"; do
  metrics_enabled="$(yq -r '.controller.metrics.enabled' "${file}")"
  assert_equal "true" "${metrics_enabled}"
  service_monitor_enabled="$(
    yq -r '.controller.metrics.serviceMonitor.enabled' "${file}"
  )"
  assert_equal "true" "${service_monitor_enabled}"
  service_monitor_interval="$(
    yq -r '.controller.metrics.serviceMonitor.interval' "${file}"
  )"
  assert_equal "30s" "${service_monitor_interval}"
  service_monitor_namespace="$(
    yq -r '.controller.metrics.serviceMonitor.namespace' "${file}"
  )"
  assert_equal "monitoring" "${service_monitor_namespace}"
done

for alert in \
  ArgoCDApplicationNotSynced \
  ArgoCDApplicationDegraded \
  ArgoCDApplicationMetricsAbsent; do
  yq -e ".spec.groups[] | select(.name == \"cluster.argocd\") |
    .rules[] | select(.alert == \"${alert}\")" "${cluster_alerts}" >/dev/null
done
