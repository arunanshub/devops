package observability

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"sigs.k8s.io/yaml"
)

const (
	networkAlertsPath     = "kubernetes/base/monitoring/network-alerts/resources/prometheusrule.yaml"
	networkDashboardPath  = "kubernetes/base/monitoring/network-alerts/resources/dashboard-configmap.yaml"
	wireGuardPlaybookPath = "ansible/playbooks/ops/cilium-wireguard-diagnostics.yml"
)

// The thresholds are pinned deliberately. The rule needs both a ratio and an
// absolute floor: 150 drops per 30m rejects the 127-drop low-traffic case seen
// on 2026-08-07, which a ratio alone reported as 0.113%. See the alert's own
// comment block for the full set of anchors.
const (
	wireGuardTxDrops   = `increase(node_network_transmit_drop_total{job="node-exporter",device="cilium_wg0"}[30m])`
	wireGuardTxPackets = `increase(node_network_transmit_packets_total{job="node-exporter",device="cilium_wg0"}[30m])`

	wireGuardDropExpr = wireGuardTxDrops + " / " + wireGuardTxPackets + " > 0.0005 and " + wireGuardTxDrops + " > 150"
)

func TestWireGuardTransmitDropAlertIsDeviceSpecific(t *testing.T) {
	var ruleFile struct {
		Spec struct {
			Groups []struct {
				Rules []struct {
					Alert       string            `yaml:"alert"`
					Expr        string            `yaml:"expr"`
					For         string            `yaml:"for"`
					Labels      map[string]string `yaml:"labels"`
					Annotations map[string]string `yaml:"annotations"`
				} `yaml:"rules"`
			} `yaml:"groups"`
		} `yaml:"spec"`
	}

	raw := readRepoFile(t, networkAlertsPath)
	require.NoError(t, yaml.Unmarshal(raw, &ruleFile), "parse network alerts")

	for _, group := range ruleFile.Spec.Groups {
		for _, rule := range group.Rules {
			if rule.Alert != "CiliumWireGuardTransmitDrops" {
				continue
			}

			assert.Equal(t, wireGuardDropExpr, rule.Expr)
			assert.Equal(t, "30m", rule.For)
			assert.Equal(t, "warning", rule.Labels["severity"])
			assert.Contains(t, rule.Annotations["summary"], "{{ $labels.instance }}")
			assert.Contains(t, rule.Annotations["description"], "cilium_wg0")
			return
		}
	}

	t.Fatal("CiliumWireGuardTransmitDrops alert not found")
}

func TestNetworkDropDashboardSeparatesWireGuardAndPhysicalNIC(t *testing.T) {
	var configMap struct {
		Metadata struct {
			Labels map[string]string `yaml:"labels"`
		} `yaml:"metadata"`
		Data map[string]string `yaml:"data"`
	}

	raw := readRepoFile(t, networkDashboardPath)
	require.NoError(t, yaml.Unmarshal(raw, &configMap), "parse dashboard ConfigMap")
	assert.Equal(t, "1", configMap.Metadata.Labels["grafana_dashboard"])

	dashboardJSON := configMap.Data["network-drops.json"]
	require.NotEmpty(t, dashboardJSON)

	var dashboard struct {
		Title  string `json:"title"`
		Panels []struct {
			Title   string `json:"title"`
			Targets []struct {
				Expr string `json:"expr"`
			} `json:"targets"`
		} `json:"panels"`
	}
	require.NoError(t, json.Unmarshal([]byte(dashboardJSON), &dashboard), "parse dashboard JSON")
	assert.Equal(t, "Network Drops: WireGuard and Physical NIC", dashboard.Title)

	var expressions []string
	for _, panel := range dashboard.Panels {
		for _, target := range panel.Targets {
			expressions = append(expressions, target.Expr)
		}
	}
	joined := strings.Join(expressions, "\n")
	assert.Contains(t, joined, `device="cilium_wg0"`)
	assert.Contains(t, joined, `device="enp7s0"`)
	assert.Contains(t, joined, "node_network_transmit_packets_total")
	assert.NotContains(t, joined, `device!~"lo|veth.+"`)
}

func TestWireGuardDiagnosticPlaybookHasBoundedCleanup(t *testing.T) {
	raw := string(readRepoFile(t, wireGuardPlaybookPath))

	for _, required := range []string{
		"ansible_play_hosts_all | length == 1",
		"wireguard_capture_duration | int >= 60",
		"wireguard_capture_duration | int <= 1800",
		"module wireguard +p",
		"module wireguard -p",
		"trap cleanup EXIT",
		"wireguard_sampler_job is defined",
		"/sys/class/net/cilium_wg0/statistics/tx_dropped",
		"always:",
		".artifacts/wireguard",
	} {
		assert.Contains(t, raw, required)
	}
}

func TestJustfileExposesGuardedWireGuardDiagnostic(t *testing.T) {
	raw := string(readRepoFile(t, "Justfile"))

	assert.Contains(t, raw, `diagnose-wireguard node="hetzner-k3s-cp-2" duration="900":`)
	assert.Contains(t, raw, `--limit {{ node }},localhost`)
	assert.Contains(t, raw, `wireguard_capture_duration={{ duration }}`)
}
