package inventory

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestBuildInventoryGroupsNodesByRoleAndSetsHostvars(t *testing.T) {
	outputs := TofuOutputs{
		ClusterName:       Output[string]{Value: "hetzner-k3s"},
		APILBPrivateIP:    Output[string]{Value: "10.0.0.100"},
		SSHPrivateKeyPath: Output[string]{Value: "~/.ssh/id_ed25519"},
		NodeIPv6Addresses: Output[NodeIPv6Addresses]{Value: NodeIPv6Addresses{
			"cp-1":     "2a01:4f8:1::1",
			"cp-2":     "2a01:4f8:1::2",
			"worker-1": "2a01:4f8:1::10",
		}},
		NodePrivateIPs: Output[NodePrivateIPs]{Value: NodePrivateIPs{
			"cp-1":     "10.0.0.2",
			"cp-2":     "10.0.0.3",
			"worker-1": "10.0.0.10",
		}},
		NodeRoles: Output[NodeRoles]{Value: NodeRoles{
			"cp-1":     RoleControlPlaneWorker,
			"cp-2":     RoleControlPlaneOnly,
			"worker-1": RoleWorker,
		}},
	}

	inv, err := Build(outputs, Options{})
	require.NoError(t, err)

	assert.Equal(
		t,
		[]string{"hetzner-k3s-cp-1", "hetzner-k3s-cp-2", "hetzner-k3s-worker-1"},
		inv.K3sNodes.Hosts,
	)
	assert.Equal(t, []string{"hetzner-k3s-cp-1", "hetzner-k3s-cp-2"}, inv.ControlPlanes.Hosts)
	assert.Equal(t, []string{"hetzner-k3s-worker-1"}, inv.Workers.Hosts)

	hostvars := inv.Meta.Hostvars["hetzner-k3s-cp-1"]
	assert.Equal(t, "2a01:4f8:1::1", hostvars.AnsibleHost)
	assert.Equal(t, "root", hostvars.AnsibleUser)
	assert.Equal(t, "cp-1", hostvars.NodeKey)
	assert.Equal(t, "cp_worker", hostvars.NodeRole)
	assert.Equal(t, "10.0.0.2", hostvars.NodePrivateIP)
	assert.Equal(t, "hetzner-k3s-cp-1", hostvars.KubernetesNodeName)
	assert.Equal(t, "10.0.0.100", hostvars.APILBPrivateIP)
	assert.NotEqual(t, "~/.ssh/id_ed25519", hostvars.AnsiblePrivateKeyFile)
}

func TestRemovedNodesDisappearWhenOutputsChange(t *testing.T) {
	outputs := TofuOutputs{
		ClusterName:       Output[string]{Value: "hetzner-k3s"},
		APILBPrivateIP:    Output[string]{Value: "10.0.0.100"},
		SSHPrivateKeyPath: Output[string]{Value: "~/.ssh/id_ed25519"},
		NodeIPv6Addresses: Output[NodeIPv6Addresses]{Value: NodeIPv6Addresses{
			"cp-1": "2a01:4f8:1::1",
			"cp-3": "2a01:4f8:1::3",
		}},
		NodePrivateIPs: Output[NodePrivateIPs]{Value: NodePrivateIPs{
			"cp-1": "10.0.0.2",
			"cp-3": "10.0.0.4",
		}},
		NodeRoles: Output[NodeRoles]{Value: NodeRoles{
			"cp-1": RoleControlPlaneWorker,
			"cp-3": RoleControlPlaneWorker,
		}},
	}

	inv, err := Build(outputs, Options{})
	require.NoError(t, err)

	assert.Equal(t, []string{"hetzner-k3s-cp-1", "hetzner-k3s-cp-3"}, inv.K3sNodes.Hosts)
	assert.NotContains(t, inv.Meta.Hostvars, "hetzner-k3s-cp-2")
}

func TestInfersGroupsDuringTransitionBeforeNodeRolesOutputExists(t *testing.T) {
	outputs := TofuOutputs{
		ClusterName:       Output[string]{Value: "hetzner-k3s"},
		APILBPrivateIP:    Output[string]{Value: "10.0.0.100"},
		SSHPrivateKeyPath: Output[string]{Value: "~/.ssh/id_ed25519"},
		NodeIPv6Addresses: Output[NodeIPv6Addresses]{Value: NodeIPv6Addresses{
			"cp-1":     "2a01:4f8:1::1",
			"worker-1": "2a01:4f8:1::10",
		}},
		NodePrivateIPs: Output[NodePrivateIPs]{Value: NodePrivateIPs{
			"cp-1":     "10.0.0.2",
			"worker-1": "10.0.0.10",
		}},
	}

	inv, err := Build(outputs, Options{})
	require.NoError(t, err)

	assert.Equal(t, []string{"hetzner-k3s-cp-1"}, inv.ControlPlanes.Hosts)
	assert.Equal(t, []string{"hetzner-k3s-worker-1"}, inv.Workers.Hosts)
	assert.Equal(t, "cp_worker", inv.Meta.Hostvars["hetzner-k3s-cp-1"].NodeRole)
}

func TestBuildInventoryRejectsUnsupportedRole(t *testing.T) {
	outputs := TofuOutputs{
		ClusterName:       Output[string]{Value: "hetzner-k3s"},
		APILBPrivateIP:    Output[string]{Value: "10.0.0.100"},
		SSHPrivateKeyPath: Output[string]{Value: "~/.ssh/id_ed25519"},
		NodeIPv6Addresses: Output[NodeIPv6Addresses]{Value: NodeIPv6Addresses{
			"cp-1": "2a01:4f8:1::1",
		}},
		NodePrivateIPs: Output[NodePrivateIPs]{Value: NodePrivateIPs{
			"cp-1": "10.0.0.2",
		}},
		NodeRoles: Output[NodeRoles]{Value: NodeRoles{
			"cp-1": "banana",
		}},
	}

	_, err := Build(outputs, Options{})
	require.Error(t, err)
}

func TestBuildInventoryRejectsUnknownInferredRole(t *testing.T) {
	outputs := TofuOutputs{
		ClusterName:       Output[string]{Value: "hetzner-k3s"},
		APILBPrivateIP:    Output[string]{Value: "10.0.0.100"},
		SSHPrivateKeyPath: Output[string]{Value: "~/.ssh/id_ed25519"},
		NodeIPv6Addresses: Output[NodeIPv6Addresses]{Value: NodeIPv6Addresses{
			"db-1": "2a01:4f8:1::20",
		}},
		NodePrivateIPs: Output[NodePrivateIPs]{Value: NodePrivateIPs{
			"db-1": "10.0.0.20",
		}},
	}

	_, err := Build(outputs, Options{})
	require.Error(t, err)
}
