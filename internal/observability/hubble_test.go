package observability

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"sigs.k8s.io/yaml"
)

const enrichedDropMetric = "drop:labelsContext=source_ip,source_namespace,source_workload," +
	"destination_ip,destination_namespace,destination_workload,traffic_direction"

func TestTraefikDisablesOutboundVersionAndUsageChecks(t *testing.T) {
	var values struct {
		Global struct {
			CheckNewVersion    *bool `yaml:"checkNewVersion"`
			SendAnonymousUsage *bool `yaml:"sendAnonymousUsage"`
		} `yaml:"global"`
	}

	raw := readRepoFile(t, "kubernetes/base/platform/traefik/values.yaml")
	require.NoError(t, yaml.Unmarshal(raw, &values), "parse Traefik values")
	require.NotNil(t, values.Global.CheckNewVersion, "set global.checkNewVersion explicitly")
	require.NotNil(t, values.Global.SendAnonymousUsage, "set global.sendAnonymousUsage explicitly")
	assert.False(t, *values.Global.CheckNewVersion)
	assert.False(t, *values.Global.SendAnonymousUsage)
}

func TestHubbleDropMetricCarriesFlowContext(t *testing.T) {
	paths := []string{
		"kubernetes/base/infra/cilium/values.yaml",
		"kubernetes/bootstrap/values/cilium.yaml.gotmpl",
	}

	for _, path := range paths {
		t.Run(filepath.Base(path), func(t *testing.T) {
			raw := readRepoFile(t, path)
			assert.Contains(t, string(raw), enrichedDropMetric)
		})
	}
}

func TestHubbleDropAlertReportsFlowContext(t *testing.T) {
	var ruleFile struct {
		Spec struct {
			Groups []struct {
				Rules []struct {
					Alert       string            `yaml:"alert"`
					Expr        string            `yaml:"expr"`
					Annotations map[string]string `yaml:"annotations"`
				} `yaml:"rules"`
			} `yaml:"groups"`
		} `yaml:"spec"`
	}

	raw := readRepoFile(t, "kubernetes/base/monitoring/network-alerts/resources/prometheusrule.yaml")
	require.NoError(t, yaml.Unmarshal(raw, &ruleFile), "parse network alerts")

	for _, group := range ruleFile.Spec.Groups {
		for _, rule := range group.Rules {
			if rule.Alert != "HubbleDropsDetected" {
				continue
			}

			context := rule.Annotations["summary"] + " " + rule.Annotations["description"]
			for _, label := range []string{
				"source_namespace", "source_workload", "source_ip",
				"destination_namespace", "destination_workload", "destination_ip",
				"traffic_direction", "protocol", "reason", "node",
			} {
				assert.Contains(t, context, "{{ $labels."+label+" }}")
			}
			assert.NotContains(t, context, "hubble observe")
			assert.Equal(t,
				`increase(hubble_drop_total{reason!="UNSUPPORTED_L3_PROTOCOL"}[5m]) > 10`,
				rule.Expr)
			return
		}
	}

	t.Fatal("HubbleDropsDetected alert not found")
}

func readRepoFile(t *testing.T, path string) []byte {
	t.Helper()

	root := filepath.Join("..", "..")
	raw, err := os.ReadFile(filepath.Join(root, path))
	require.NoError(t, err, "read %s", path)
	return raw
}
