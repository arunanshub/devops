# METADATA
# title: Platform intent
# description: Invariants for specific platform components.
package kubernetes.platform

import data.lib.k8s
import rego.v1

# METADATA
# title: hcloud-csi runs at critical priority
# description: |
#   The CSI controller and node plugin are on the critical path for every volume.
#   The chart reads priorityClassName only under controller.* and node.*; a
#   root-level key is silently ignored (7933d61).
deny_csi_critical_priority contains msg if {
	input.metadata.labels["app.kubernetes.io/name"] == "hcloud-csi"
	priority := object.get(k8s.pod_spec(input), "priorityClassName", "")
	not regex.match(`^system-(cluster|node)-critical$`, priority)
	msg := $"{k8s.label(input)}: hcloud-csi must run at system-*-critical priority (controller./node.priorityClassName)"
}

# METADATA
# title: Traefik sends no anonymous usage
# description: |
#   Telemetry stays off regardless of the chart default: the chart passes
#   --global.sendAnonymousUsage only when the value is true (a9670ba).
deny_traefik_no_telemetry contains msg if {
	input.kind == "Deployment"
	input.metadata.name == "traefik"
	msg := $"{k8s.label(input)}: global.sendAnonymousUsage must stay false"
	some c in k8s.app_containers(input)
	some a in object.get(c, "args", [])
	startswith(a, "--global.sendAnonymousUsage")
}
