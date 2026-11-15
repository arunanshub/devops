package main

import rego.v1

workload_kinds := {"Deployment", "DaemonSet", "StatefulSet"}

deny contains msg if {
	workload_kinds[input.kind]
	some c in input.spec.template.spec.containers
	c.resources.limits.cpu
	msg := sprintf("%s/%s container %s: CPU limits are not allowed", [input.kind, input.metadata.name, c.name])
}
