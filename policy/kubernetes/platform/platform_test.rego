package kubernetes.platform_test

import data.kubernetes.platform
import rego.v1

csi(kind, spec) := {
	"kind": kind,
	"metadata": {
		"name": "hcloud-csi-x", "namespace": "kube-system",
		"labels": {"app.kubernetes.io/name": "hcloud-csi"},
	},
	"spec": {"template": {"spec": spec}},
}

test_csi_with_critical_priority_passes if {
	pod := {"priorityClassName": "system-cluster-critical", "containers": []}
	count(platform.deny_csi_critical_priority) == 0 with input as csi("Deployment", pod)
}

test_csi_without_priority_denied if {
	count(platform.deny_csi_critical_priority) == 1 with input as csi("DaemonSet", {"containers": []})
}

test_csi_with_other_priority_denied if {
	pod := {"priorityClassName": "high", "containers": []}
	count(platform.deny_csi_critical_priority) == 1 with input as csi("DaemonSet", pod)
}

traefik(args) := {
	"kind": "Deployment",
	"metadata": {"name": "traefik", "namespace": "traefik"},
	"spec": {"template": {"spec": {"containers": [{"name": "traefik", "args": args}]}}},
}

test_traefik_without_telemetry_passes if {
	count(platform.deny_traefik_no_telemetry) == 0 with input as traefik(["--entryPoints.web.address=:8000"])
}

test_traefik_telemetry_denied if {
	count(platform.deny_traefik_no_telemetry) == 1 with input as traefik(["--global.sendAnonymousUsage"])
}
