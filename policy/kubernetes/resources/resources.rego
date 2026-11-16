# METADATA
# title: Resource limits
# description: House rules for container resources.
package kubernetes.resources

import data.exceptions
import data.lib.k8s
import rego.v1

long_running := {"Deployment", "DaemonSet", "StatefulSet"}

# METADATA
# title: No CPU limits
# description: |
#   CPU is compressible; a limit only adds CFS throttling. Chart defaults are the
#   usual source: omitting a key lets Helm merge the default back, so set
#   `resources.limits.cpu: null` in the values (descheduler ca39949, KEDA #290,
#   cilium #291).
deny_no_cpu_limits contains msg if {
	some c in k8s.containers(input)
	c.resources.limits.cpu
	msg := $"{k8s.label(input)}: container {c.name} has a CPU limit; set resources.limits.cpu: null in the chart values"
}

# METADATA
# title: Memory limit on every long-running container
# description: |
#   A memory limit protects the node from steady growth in long-running pods.
#   Jobs and CronJobs are out of scope: they run for seconds (hubble certgen runs
#   every 4 months for ~5 s and has no usage data to size a limit from).
#   Deliberate exceptions live in policy/data/exceptions.yaml with a reason.
deny_memory_limits contains msg if {
	input.kind in long_running
	some c in k8s.app_containers(input)
	not c.resources.limits.memory
	not exempt(exceptions.memory_limits, input, c)
	msg := $"{k8s.label(input)}: container {c.name} has no memory limit"
}

# exempt is true when an entry names exactly this kind, namespace, name and container.
exempt(entries, obj, c) if {
	some e in entries
	e.kind == obj.kind
	e.namespace == obj.metadata.namespace
	e.name == obj.metadata.name
	e.container == c.name
}
