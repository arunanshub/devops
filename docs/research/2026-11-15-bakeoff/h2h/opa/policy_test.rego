package main

import rego.v1

deploy(name, ns, spec) := {"kind": "Deployment", "metadata": {"name": name, "namespace": ns}, "spec": {"template": {"spec": spec}}}

mem := {"limits": {"memory": "128Mi"}}

test_ok_passes if {
	count(deny_no_cpu_limits) == 0 with input as deploy("ok", "apps", {"containers": [{"name": "app", "resources": mem}]})
}

test_cpu_limit_denied if {
	count(deny_no_cpu_limits) == 1 with input as deploy("bad", "apps", {"containers": [{"name": "app", "resources": {"limits": {"cpu": "1", "memory": "128Mi"}}}]})
}

test_init_cpu_limit_denied if {
	count(deny_no_cpu_limits) == 1 with input as deploy("bad", "apps", {
		"initContainers": [{"name": "init", "resources": {"limits": {"cpu": "100m"}}}],
		"containers": [{"name": "app", "resources": mem}],
	})
}

test_no_memory_limit_denied if {
	count(deny_memory_limits) == 1 with input as deploy("bad", "apps", {"containers": [{"name": "app"}]})
}

test_velero_memory_exception if {
	exception == {["memory_limits"]} with input as deploy("velero", "velero", {"containers": [{"name": "velero"}]})
}

test_csi_controller_ok if {
	count(deny_csi_critical_priority) == 0 with input as {
		"kind": "Deployment",
		"metadata": {"name": "hcloud-csi-controller", "labels": {"app.kubernetes.io/name": "hcloud-csi"}},
		"spec": {"template": {"spec": {"priorityClassName": "system-cluster-critical", "containers": []}}},
	}
}

test_csi_node_without_priority_denied if {
	count(deny_csi_critical_priority) == 1 with input as {
		"kind": "DaemonSet",
		"metadata": {"name": "hcloud-csi-node", "labels": {"app.kubernetes.io/name": "hcloud-csi"}},
		"spec": {"template": {"spec": {"containers": []}}},
	}
}

test_traefik_telemetry_denied if {
	count(deny_traefik_no_telemetry) == 1 with input as deploy("traefik", "traefik", {"containers": [{"name": "traefik", "args": ["--global.sendAnonymousUsage"]}]})
}

test_null_init_containers_still_checked if {
	count(deny_no_cpu_limits) == 1 with input as deploy("bad", "apps", {
		"initContainers": null,
		"containers": [{"name": "app", "resources": {"limits": {"cpu": "1"}}}],
	})
}
