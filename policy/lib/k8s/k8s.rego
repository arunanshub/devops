# METADATA
# title: Kubernetes helpers
# description: Pod spec and container accessors shared by the kubernetes.* policies.
package lib.k8s

import rego.v1

pod_kinds := {"Deployment", "DaemonSet", "StatefulSet", "ReplicaSet", "Job"}

# pod_spec is the pod template of any workload kind, CronJob included.
pod_spec(obj) := obj.spec.template.spec if obj.kind in pod_kinds

pod_spec(obj) := obj.spec.jobTemplate.spec.template.spec if obj.kind == "CronJob"

# One rule per source: an explicit `initContainers: null` (the hcloud-csi chart
# renders one) empties only that rule instead of making the whole set undefined.
containers(obj) := {c | some c in pod_spec(obj).containers} | {c | some c in pod_spec(obj).initContainers}

app_containers(obj) := {c | some c in pod_spec(obj).containers}

# label identifies an object in messages: Kind/namespace/name.
label(obj) := $"{obj.kind}/{object.get(obj.metadata, "namespace", "")}/{obj.metadata.name}"
