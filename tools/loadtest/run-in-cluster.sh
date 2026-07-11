#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

kubeconfig="${repo_root}/infra/kubeconfig.yaml"
namespace="arunanshu-dev"
profile="capacity"
confirmed=false
keep=false
dry_run=false

usage() {
  echo "Usage: $0 [--smoke] [--keep] [--kubeconfig PATH] --yes"
  echo "       $0 --dry-run [--smoke] [--kubeconfig PATH]"
}

while (($# > 0)); do
  case "$1" in
    --yes) confirmed=true ;;
    --keep) keep=true ;;
    --smoke) profile="smoke" ;;
    --dry-run) dry_run=true ;;
    --kubeconfig)
      shift
      kubeconfig="${1:?--kubeconfig requires a path}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "${dry_run}" != true && "${confirmed}" != true ]]; then
  echo "Refusing to generate load without --yes" >&2
  exit 2
fi

run_id="${RUN_ID:-$(date -u +%Y%m%d%H%M%S)-${RANDOM}${RANDOM}}"
if ! [[ "${run_id}" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]]; then
  echo "RUN_ID must contain only lowercase letters, numbers, and hyphens" >&2
  exit 2
fi
name="arunanshu-dev-k6-${run_id}"
test_script="${script_dir}/arunanshu-dev.js"

kubectl_cmd=(kubectl --kubeconfig "${kubeconfig}" --namespace "${namespace}")

render_configmap() {
  "${kubectl_cmd[@]}" create configmap "${name}" \
    --from-file="test.js=${test_script}" \
    --dry-run=client \
    --output=yaml
}

render_job() {
  cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: k6
    app.kubernetes.io/part-of: arunanshu-dev
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 480
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: k6
        app.kubernetes.io/part-of: arunanshu-dev
    spec:
      automountServiceAccountToken: false
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 12345
        runAsGroup: 12345
        seccompProfile:
          type: RuntimeDefault
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels:
                    app: arunanshu-dev
      containers:
        - name: k6
          image: grafana/k6:2.1.0
          imagePullPolicy: IfNotPresent
          args:
            - run
            - --quiet
            - /scripts/test.js
          env:
            - name: TARGET_URL
              value: http://traefik.traefik.svc.cluster.local/blog/next-server-actions-client-side-data-fetching
            - name: METHOD
              value: GET
            - name: PROFILE
              value: ${profile}
            - name: K6_SUMMARY_TREND_STATS
              value: avg,min,med,max,p(90),p(95),p(99)
          resources:
            requests:
              cpu: 250m
              memory: 128Mi
            limits:
              cpu: "1"
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: script
          configMap:
            name: ${name}
        - name: tmp
          emptyDir: {}
EOF
}

if [[ "${dry_run}" == true ]]; then
  render_configmap
  echo "---"
  render_job
  exit 0
fi

# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  if [[ "${keep}" == true ]]; then
    echo "Keeping Job and ConfigMap ${name}"
    return
  fi
  if [[ "${job_created}" == true ]]; then
    "${kubectl_cmd[@]}" delete job "${name}" --ignore-not-found --wait=false >/dev/null
  fi
  if [[ "${configmap_created}" == true ]]; then
    "${kubectl_cmd[@]}" delete configmap "${name}" --ignore-not-found --wait=false >/dev/null
  fi
}
configmap_created=false
job_created=false
trap cleanup EXIT

snapshot() {
  echo
  echo "HPA:"
  "${kubectl_cmd[@]}" get hpa keda-hpa-arunanshu-dev
  echo
  echo "Application pods:"
  "${kubectl_cmd[@]}" get pods -l app=arunanshu-dev
  echo
  echo "Tempo:"
  kubectl --kubeconfig "${kubeconfig}" --namespace monitoring get pod tempo-0
}

echo "Creating ${profile} GET load test ${name}"
snapshot
scaled_ready="$("${kubectl_cmd[@]}" get scaledobject arunanshu-dev -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
scaled_fallback="$("${kubectl_cmd[@]}" get scaledobject arunanshu-dev -o jsonpath='{.status.conditions[?(@.type=="Fallback")].status}')"
if [[ "${scaled_ready}" != "True" || "${scaled_fallback}" == "True" ]]; then
  echo "KEDA ScaledObject is not ready or is using fallback" >&2
  exit 1
fi

baseline_replicas="$("${kubectl_cmd[@]}" get hpa keda-hpa-arunanshu-dev -o jsonpath='{.status.currentReplicas}')"
max_replicas="${baseline_replicas}"
metric_seen=false

render_configmap | "${kubectl_cmd[@]}" create -f - >/dev/null
configmap_created=true
render_job | "${kubectl_cmd[@]}" create -f - >/dev/null
job_created=true

result=1
for _ in {1..100}; do
  succeeded="$("${kubectl_cmd[@]}" get job "${name}" -o jsonpath='{.status.succeeded}')"
  failed="$("${kubectl_cmd[@]}" get job "${name}" -o jsonpath='{.status.failed}')"

  if [[ "${succeeded:-0}" -ge 1 ]]; then
    result=0
    break
  fi
  if [[ "${failed:-0}" -ge 1 ]]; then
    break
  fi

  current_replicas="$("${kubectl_cmd[@]}" get hpa keda-hpa-arunanshu-dev -o jsonpath='{.status.currentReplicas}')"
  desired_replicas="$("${kubectl_cmd[@]}" get hpa keda-hpa-arunanshu-dev -o jsonpath='{.status.desiredReplicas}')"
  current_metric="$("${kubectl_cmd[@]}" get hpa keda-hpa-arunanshu-dev -o jsonpath='{.status.currentMetrics[0].external.current.averageValue}')"
  target_metric="$("${kubectl_cmd[@]}" get hpa keda-hpa-arunanshu-dev -o jsonpath='{.spec.metrics[0].external.target.averageValue}')"

  if [[ -n "${current_metric}" ]]; then
    metric_seen=true
  fi
  if [[ "${current_replicas}" -gt "${max_replicas}" ]]; then
    max_replicas="${current_replicas}"
  fi
  printf 'replicas=%s desired=%s metric=%s target=%s\n' \
    "${current_replicas}" "${desired_replicas}" "${current_metric:-none}" "${target_metric}"
  sleep 5
done

echo
echo "k6 output:"
"${kubectl_cmd[@]}" logs "job/${name}" || true

pod_name="$("${kubectl_cmd[@]}" get pods -l "job-name=${name}" -o jsonpath='{.items[0].metadata.name}')"
container_exit="$("${kubectl_cmd[@]}" get pod "${pod_name}" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')"
if [[ "${container_exit}" =~ ^[0-9]+$ ]]; then
  result="${container_exit}"
else
  echo "Job ended without a k6 container exit code; treating it as an infrastructure failure" >&2
  result=1
fi

if [[ "${profile}" == "capacity" && "${result}" -eq 0 ]]; then
  if [[ "${metric_seen}" != true ]]; then
    echo "KEDA did not expose an external metric during the capacity run" >&2
    result=1
  elif [[ "${max_replicas}" -le "${baseline_replicas}" ]]; then
    echo "KEDA did not scale above the baseline of ${baseline_replicas} replicas" >&2
    result=1
  else
    echo "KEDA scaled from ${baseline_replicas} to ${max_replicas} replicas"
  fi
fi
snapshot

if [[ "${result}" -ne 0 ]]; then
  echo "Load test or infrastructure validation failed with exit code ${result}; rerun with --keep to preserve resources" >&2
fi
exit "${result}"
