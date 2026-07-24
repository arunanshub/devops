// Package inventory builds the Ansible dynamic inventory from OpenTofu
// outputs. Groups: k3s_nodes (all), control_planes, workers. Hostnames follow
// the <cluster_name>-<node_key> convention, which by design equals the live
// kubernetes Node name.
package inventory

import (
	"cmp"
	"errors"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// DefaultKnownHosts is the repo-relative SSH known-hosts file used when no
// override is given.
const DefaultKnownHosts = "infra/.ssh_known_hosts"

const defaultClusterName = "hetzner-k3s"

// Output is the generic wrapper OpenTofu puts around each output value.
type Output[T any] struct {
	Value T `json:"value"`
}

// NodeKey is the per-node key used in tofu outputs (e.g. "cp-1").
type NodeKey string

// IPv6Address is a node's public IPv6 address.
type IPv6Address string

// PrivateIP is a node's Hetzner private-network IPv4 address.
type PrivateIP string

// NodeRole describes what a node does in the cluster.
type NodeRole string

// The set of node roles the inventory understands.
const (
	RoleControlPlaneOnly   NodeRole = "cp_only"
	RoleControlPlaneWorker NodeRole = "cp_worker"
	RoleWorker             NodeRole = "worker"
	RoleUnknown            NodeRole = "unknown"
)

// Per-node output maps keyed by node key.
type (
	NodeIPv6Addresses map[NodeKey]IPv6Address
	NodePrivateIPs    map[NodeKey]PrivateIP
	NodeRoles         map[NodeKey]NodeRole
)

// TofuOutputs is the subset of `tofu output -json` the inventory consumes.
type TofuOutputs struct {
	ClusterName       Output[string]            `json:"cluster_name"`
	APILBPrivateIP    Output[string]            `json:"api_lb_private_ip"`
	SSHPrivateKeyPath Output[string]            `json:"ssh_private_key_path"`
	NodeIPv6Addresses Output[NodeIPv6Addresses] `json:"node_ipv6_addresses"`
	NodePrivateIPs    Output[NodePrivateIPs]    `json:"node_private_ips"`
	NodeRoles         Output[NodeRoles]         `json:"node_roles"`
}

// Inventory is the Ansible dynamic-inventory JSON document.
type Inventory struct {
	Meta          Meta  `json:"_meta"`
	K3sNodes      Group `json:"k3s_nodes"`
	ControlPlanes Group `json:"control_planes"`
	Workers       Group `json:"workers"`
}

// Meta holds per-host variables.
type Meta struct {
	Hostvars map[string]Hostvars `json:"hostvars"`
}

// Group is a named set of hosts.
type Group struct {
	Hosts []string `json:"hosts"`
}

// Hostvars are the Ansible variables emitted for one host.
type Hostvars struct {
	AnsibleHost           string `json:"ansible_host"`
	AnsibleUser           string `json:"ansible_user"`
	AnsiblePrivateKeyFile string `json:"ansible_private_key_file"`
	AnsibleSSHCommonArgs  string `json:"ansible_ssh_common_args"`
	NodeKey               string `json:"node_key"`
	NodeRole              string `json:"node_role"`
	NodePrivateIP         string `json:"node_private_ip"`
	KubernetesNodeName    string `json:"kubernetes_node_name"`
	APILBPrivateIP        string `json:"api_lb_private_ip"`
}

// Options overrides values that would otherwise come from tofu outputs or
// defaults.
type Options struct {
	SSHPrivateKeyPath string
	KnownHostsPath    string
}

// Build converts tofu outputs into an Ansible inventory.
func Build(outputs TofuOutputs, opts Options) (*Inventory, error) {
	clusterName := cmp.Or(outputs.ClusterName.Value, defaultClusterName)
	if len(outputs.NodeIPv6Addresses.Value) == 0 {
		return nil, errors.New("node_ipv6_addresses output is empty")
	}

	sshPrivateKeyPath := cmp.Or(
		opts.SSHPrivateKeyPath,
		outputs.SSHPrivateKeyPath.Value,
		"~/.ssh/id_ed25519",
	)
	knownHostsPath, err := filepath.Abs(cmp.Or(opts.KnownHostsPath, DefaultKnownHosts))
	if err != nil {
		return nil, fmt.Errorf("resolve known hosts path: %w", err)
	}

	inv := &Inventory{
		Meta:          Meta{Hostvars: map[string]Hostvars{}},
		K3sNodes:      Group{Hosts: []string{}},
		ControlPlanes: Group{Hosts: []string{}},
		Workers:       Group{Hosts: []string{}},
	}

	nodeKeys := slices.Sorted(maps.Keys(outputs.NodeIPv6Addresses.Value))
	for _, nodeKey := range nodeKeys {
		hostname := clusterName + "-" + string(nodeKey)
		role := outputs.NodeRoles.Value[nodeKey]
		if role == "" {
			role = inferredRole(nodeKey)
		}
		if !role.valid() {
			return nil, fmt.Errorf("node %q has unsupported role %q", nodeKey, role)
		}

		nodePrivateIP, ok := outputs.NodePrivateIPs.Value[nodeKey]
		if !ok || nodePrivateIP == "" {
			return nil, fmt.Errorf("node %q is missing node_private_ips output", nodeKey)
		}

		inv.K3sNodes.Hosts = append(inv.K3sNodes.Hosts, hostname)
		switch role {
		case RoleControlPlaneOnly, RoleControlPlaneWorker:
			inv.ControlPlanes.Hosts = append(inv.ControlPlanes.Hosts, hostname)
		case RoleWorker:
			inv.Workers.Hosts = append(inv.Workers.Hosts, hostname)
		case RoleUnknown:
			return nil, fmt.Errorf("how did we hit role unknown! This should be impossible")
		}

		inv.Meta.Hostvars[hostname] = Hostvars{
			AnsibleHost:           string(outputs.NodeIPv6Addresses.Value[nodeKey]),
			AnsibleUser:           "root",
			AnsiblePrivateKeyFile: expandHome(sshPrivateKeyPath),
			AnsibleSSHCommonArgs:  sshCommonArgs(knownHostsPath),
			NodeKey:               string(nodeKey),
			NodeRole:              string(role),
			NodePrivateIP:         string(nodePrivateIP),
			KubernetesNodeName:    hostname,
			APILBPrivateIP:        outputs.APILBPrivateIP.Value,
		}
	}

	return inv, nil
}

func inferredRole(nodeKey NodeKey) NodeRole {
	switch {
	case strings.HasPrefix(string(nodeKey), "cp-"):
		return RoleControlPlaneWorker
	case strings.HasPrefix(string(nodeKey), "worker-"):
		return RoleWorker
	default:
		return RoleUnknown
	}
}

func (role NodeRole) valid() bool {
	switch role {
	case RoleControlPlaneOnly, RoleControlPlaneWorker, RoleWorker:
		return true
	case RoleUnknown:
		return false
	default:
		return false
	}
}

func sshCommonArgs(knownHostsPath string) string {
	return "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=" + knownHostsPath
}

func expandHome(path string) string {
	if path == "~" {
		home, err := os.UserHomeDir()
		if err == nil {
			return home
		}
	}
	if strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err == nil {
			return filepath.Join(home, strings.TrimPrefix(path, "~/"))
		}
	}
	return path
}
