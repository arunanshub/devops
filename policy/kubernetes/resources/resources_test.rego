package kubernetes.resources_test

import data.kubernetes.resources
import rego.v1

deploy(spec) := {
	"kind": "Deployment",
	"metadata": {"name": "app", "namespace": "apps"},
	"spec": {"template": {"spec": spec}},
}

mem := {"limits": {"memory": "128Mi"}}

cpu_limit := {"limits": {"cpu": "1"}}

app_exception := {"memory_limits": [{
	"kind": "Deployment", "namespace": "apps", "name": "app",
	"container": "app", "reason": "test",
}]}

test_memory_only_limits_pass if {
	count(resources.deny_no_cpu_limits) == 0 with input as deploy({"containers": [{"name": "app", "resources": mem}]})
}

test_cpu_limit_denied if {
	pod := {"containers": [{"name": "app", "resources": cpu_limit}]}
	count(resources.deny_no_cpu_limits) == 1 with input as deploy(pod)
}

test_init_container_cpu_limit_denied if {
	count(resources.deny_no_cpu_limits) == 1 with input as deploy({
		"initContainers": [{"name": "init", "resources": cpu_limit}],
		"containers": [{"name": "app", "resources": mem}],
	})
}

test_null_init_containers_still_checked if {
	count(resources.deny_no_cpu_limits) == 1 with input as deploy({
		"initContainers": null,
		"containers": [{"name": "app", "resources": cpu_limit}],
	})
}

test_cronjob_cpu_limit_denied if {
	pod := {"containers": [{"name": "j", "resources": cpu_limit}]}
	count(resources.deny_no_cpu_limits) == 1 with input as {
		"kind": "CronJob",
		"metadata": {"name": "job", "namespace": "apps"},
		"spec": {"jobTemplate": {"spec": {"template": {"spec": pod}}}},
	}
}

test_missing_memory_limit_denied if {
	count(resources.deny_memory_limits) == 1 with input as deploy({"containers": [{"name": "app"}]})
}

test_memory_limit_exception_applies if {
	count(resources.deny_memory_limits) == 0 with input as deploy({"containers": [{"name": "app"}]})
		with data.exceptions as app_exception
}

test_exception_is_exact_per_container if {
	count(resources.deny_memory_limits) == 1 with input as deploy({"containers": [{"name": "app"}, {"name": "sidecar"}]})
		with data.exceptions as app_exception
}

test_every_exception_has_a_reason if {
	every entries in data.exceptions {
		every e in entries {
			trim_space(object.get(e, "reason", "")) != ""
		}
	}
}

test_jobs_out_of_memory_scope if {
	count(resources.deny_memory_limits) == 0 with input as {
		"kind": "Job",
		"metadata": {"name": "job", "namespace": "apps"},
		"spec": {"template": {"spec": {"containers": [{"name": "j"}]}}},
	}
}
