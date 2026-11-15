package main

import rego.v1

workload_kinds := {"Deployment", "DaemonSet", "StatefulSet"}

pod := input.spec.template.spec if workload_kinds[input.kind]

# Each source is its own rule: an explicit `initContainers: null` (hcloud-csi)
# makes only that rule empty instead of making the whole set undefined.
containers contains c if some c in pod.containers

containers contains c if some c in pod.initContainers

# House rule: no CPU limits (CPU is compressible; limits cause CFS throttling).
deny_no_cpu_limits contains msg if {
	some c in containers
	c.resources.limits.cpu
	msg := sprintf("%s/%s: CPU limit on container %s; set resources.limits.cpu: null in the chart values", [input.kind, input.metadata.name, c.name])
}

# Every container sets a memory limit (node protection). Exceptions below.
deny_memory_limits contains msg if {
	some c in pod.containers
	not c.resources.limits.memory
	msg := sprintf("%s/%s: no memory limit on container %s", [input.kind, input.metadata.name, c.name])
}

# The CSI controller and node plugin are on the critical path for every volume.
deny_csi_critical_priority contains msg if {
	input.metadata.labels["app.kubernetes.io/name"] == "hcloud-csi"
	not regex.match(`^system-(cluster|node)-critical$`, object.get(pod, "priorityClassName", ""))
	msg := sprintf("%s/%s: hcloud-csi must run at system-*-critical priority (set controller./node.priorityClassName)", [input.kind, input.metadata.name])
}

# Traefik telemetry stays off regardless of the chart default.
deny_traefik_no_telemetry contains msg if {
	input.kind == "Deployment"
	input.metadata.name == "traefik"
	some c in pod.containers
	some a in object.get(c, "args", [])
	startswith(a, "--global.sendAnonymousUsage")
	msg := "traefik must not send anonymous usage (global.sendAnonymousUsage must stay false)"
}

# velero: limitless on purpose; the backup job must not be OOM-capped (VPA RequestsOnly).
exception contains rules if {
	input.kind == "Deployment"
	input.metadata.namespace == "velero"
	input.metadata.name == "velero"
	rules := ["memory_limits"]
}

# cilium-agent: an OOM-killed CNI agent takes node networking down (assumed; confirm).
exception contains rules if {
	input.kind == "DaemonSet"
	input.metadata.name == "cilium"
	rules := ["memory_limits"]
}
