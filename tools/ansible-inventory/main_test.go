package main

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestBuildInventoryGroupsNodesByRoleAndSetsHostvars(t *testing.T) {
	outputs := tofuOutputs{
		ClusterName:       output[string]{Value: "hetzner-k3s"},
		APILBPrivateIP:    output[string]{Value: "10.0.0.100"},
		SSHPrivateKeyPath: output[string]{Value: "~/.ssh/id_ed25519"},
		NodeIPv6Addresses: output[nodeIPv6Addresses]{Value: nodeIPv6Addresses{
			"cp-1":     "2a01:4f8:1::1",
			"cp-2":     "2a01:4f8:1::2",
			"worker-1": "2a01:4f8:1::10",
		}},
		NodePrivateIPs: output[nodePrivateIPs]{Value: nodePrivateIPs{
			"cp-1":     "10.0.0.2",
			"cp-2":     "10.0.0.3",
			"worker-1": "10.0.0.10",
		}},
		NodeRoles: output[nodeRoles]{Value: nodeRoles{
			"cp-1":     roleControlPlaneWorker,
			"cp-2":     roleControlPlaneOnly,
			"worker-1": roleWorker,
		}},
	}

	inventory, err := buildInventory(outputs, inventoryOptions{})
	require.NoError(t, err)

	assert.Equal(t, []string{"hetzner-k3s-cp-1", "hetzner-k3s-cp-2", "hetzner-k3s-worker-1"}, inventory.K3sNodes.Hosts)
	assert.Equal(t, []string{"hetzner-k3s-cp-1", "hetzner-k3s-cp-2"}, inventory.ControlPlanes.Hosts)
	assert.Equal(t, []string{"hetzner-k3s-worker-1"}, inventory.Workers.Hosts)

	hostvars := inventory.Meta.Hostvars["hetzner-k3s-cp-1"]
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
	outputs := tofuOutputs{
		ClusterName:       output[string]{Value: "hetzner-k3s"},
		APILBPrivateIP:    output[string]{Value: "10.0.0.100"},
		SSHPrivateKeyPath: output[string]{Value: "~/.ssh/id_ed25519"},
		NodeIPv6Addresses: output[nodeIPv6Addresses]{Value: nodeIPv6Addresses{
			"cp-1": "2a01:4f8:1::1",
			"cp-3": "2a01:4f8:1::3",
		}},
		NodePrivateIPs: output[nodePrivateIPs]{Value: nodePrivateIPs{
			"cp-1": "10.0.0.2",
			"cp-3": "10.0.0.4",
		}},
		NodeRoles: output[nodeRoles]{Value: nodeRoles{
			"cp-1": roleControlPlaneWorker,
			"cp-3": roleControlPlaneWorker,
		}},
	}

	inventory, err := buildInventory(outputs, inventoryOptions{})
	require.NoError(t, err)

	assert.Equal(t, []string{"hetzner-k3s-cp-1", "hetzner-k3s-cp-3"}, inventory.K3sNodes.Hosts)
	assert.NotContains(t, inventory.Meta.Hostvars, "hetzner-k3s-cp-2")
}

func TestInfersGroupsDuringTransitionBeforeNodeRolesOutputExists(t *testing.T) {
	outputs := tofuOutputs{
		ClusterName:       output[string]{Value: "hetzner-k3s"},
		APILBPrivateIP:    output[string]{Value: "10.0.0.100"},
		SSHPrivateKeyPath: output[string]{Value: "~/.ssh/id_ed25519"},
		NodeIPv6Addresses: output[nodeIPv6Addresses]{Value: nodeIPv6Addresses{
			"cp-1":     "2a01:4f8:1::1",
			"worker-1": "2a01:4f8:1::10",
		}},
		NodePrivateIPs: output[nodePrivateIPs]{Value: nodePrivateIPs{
			"cp-1":     "10.0.0.2",
			"worker-1": "10.0.0.10",
		}},
	}

	inventory, err := buildInventory(outputs, inventoryOptions{})
	require.NoError(t, err)

	assert.Equal(t, []string{"hetzner-k3s-cp-1"}, inventory.ControlPlanes.Hosts)
	assert.Equal(t, []string{"hetzner-k3s-worker-1"}, inventory.Workers.Hosts)
	assert.Equal(t, "cp_worker", inventory.Meta.Hostvars["hetzner-k3s-cp-1"].NodeRole)
}

func TestBuildInventoryRejectsUnsupportedRole(t *testing.T) {
	outputs := tofuOutputs{
		ClusterName:       output[string]{Value: "hetzner-k3s"},
		APILBPrivateIP:    output[string]{Value: "10.0.0.100"},
		SSHPrivateKeyPath: output[string]{Value: "~/.ssh/id_ed25519"},
		NodeIPv6Addresses: output[nodeIPv6Addresses]{Value: nodeIPv6Addresses{
			"cp-1": "2a01:4f8:1::1",
		}},
		NodePrivateIPs: output[nodePrivateIPs]{Value: nodePrivateIPs{
			"cp-1": "10.0.0.2",
		}},
		NodeRoles: output[nodeRoles]{Value: nodeRoles{
			"cp-1": "banana",
		}},
	}

	_, err := buildInventory(outputs, inventoryOptions{})
	require.Error(t, err)
}

func TestBuildInventoryRejectsUnknownInferredRole(t *testing.T) {
	outputs := tofuOutputs{
		ClusterName:       output[string]{Value: "hetzner-k3s"},
		APILBPrivateIP:    output[string]{Value: "10.0.0.100"},
		SSHPrivateKeyPath: output[string]{Value: "~/.ssh/id_ed25519"},
		NodeIPv6Addresses: output[nodeIPv6Addresses]{Value: nodeIPv6Addresses{
			"db-1": "2a01:4f8:1::20",
		}},
		NodePrivateIPs: output[nodePrivateIPs]{Value: nodePrivateIPs{
			"db-1": "10.0.0.20",
		}},
	}

	_, err := buildInventory(outputs, inventoryOptions{})
	require.Error(t, err)
}
