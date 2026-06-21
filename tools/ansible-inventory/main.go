package main

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"

	"github.com/caarlos0/env/v11"
)

const (
	defaultClusterName = "hetzner-k3s"
	defaultKnownHosts  = "infra/.ssh_known_hosts"
)

type output[T any] struct {
	Value T `json:"value"`
}

type (
	nodeKey     string
	ipv6Address string
	privateIP   string
	nodeRole    string
)

const (
	roleControlPlaneOnly   nodeRole = "cp_only"
	roleControlPlaneWorker nodeRole = "cp_worker"
	roleWorker             nodeRole = "worker"
	roleUnknown            nodeRole = "unknown"
)

type (
	nodeIPv6Addresses map[nodeKey]ipv6Address
	nodePrivateIPs    map[nodeKey]privateIP
	nodeRoles         map[nodeKey]nodeRole
)

type tofuOutputs struct {
	ClusterName       output[string]            `json:"cluster_name"`
	APILBPrivateIP    output[string]            `json:"api_lb_private_ip"`
	SSHPrivateKeyPath output[string]            `json:"ssh_private_key_path"`
	NodeIPv6Addresses output[nodeIPv6Addresses] `json:"node_ipv6_addresses"`
	NodePrivateIPs    output[nodePrivateIPs]    `json:"node_private_ips"`
	NodeRoles         output[nodeRoles]         `json:"node_roles"`
}

type inventory struct {
	Meta          meta  `json:"_meta"`
	K3sNodes      group `json:"k3s_nodes"`
	ControlPlanes group `json:"control_planes"`
	Workers       group `json:"workers"`
}

type meta struct {
	Hostvars map[string]hostvars `json:"hostvars"`
}

type group struct {
	Hosts []string `json:"hosts"`
}

type hostvars struct {
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

type inventoryOptions struct {
	SSHPrivateKeyPath string
	KnownHostsPath    string
}

type config struct {
	TofuOutputsPath   string `env:"ANSIBLE_TOFU_OUTPUTS"`
	TofuChdir         string `env:"TOFU_CHDIR"                   envDefault:"infra"`
	SSHPrivateKeyPath string `env:"ANSIBLE_SSH_PRIVATE_KEY_FILE"`
	KnownHostsPath    string `env:"ANSIBLE_KNOWN_HOSTS_FILE"     envDefault:"infra/.ssh_known_hosts"`
}

func main() {
	list := flag.Bool("list", false, "print full inventory")
	host := flag.String("host", "", "print variables for one host")
	flag.Parse()

	cfg, err := env.ParseAs[config]()
	if err != nil {
		fmt.Fprintf(os.Stderr, "parse env: %v\n", err)
		os.Exit(1)
	}

	outputs, err := loadOutputs(cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "load tofu outputs: %v\n", err)
		os.Exit(1)
	}

	inv, err := buildInventory(outputs, inventoryOptions{
		SSHPrivateKeyPath: cfg.SSHPrivateKeyPath,
		KnownHostsPath:    cfg.KnownHostsPath,
	})
	if err != nil || inv == nil {
		fmt.Fprintf(os.Stderr, "build inventory: %v\n", err)
		os.Exit(1)
	}

	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")

	switch {
	case *host != "":
		hostvars, ok := inv.Meta.Hostvars[*host]
		if !ok {
			if err := encoder.Encode(map[string]any{}); err != nil {
				fmt.Fprintf(os.Stderr, "encode empty hostvars: %v\n", err)
				os.Exit(1)
			}
			return
		}
		if err := encoder.Encode(hostvars); err != nil {
			fmt.Fprintf(os.Stderr, "encode hostvars: %v\n", err)
			os.Exit(1)
		}
	case *list:
		if err := encoder.Encode(inv); err != nil {
			fmt.Fprintf(os.Stderr, "encode inventory: %v\n", err)
			os.Exit(1)
		}
	default:
		flag.Usage()
		os.Exit(1)
	}
}

func loadOutputs(cfg config) (tofuOutputs, error) {
	var outputs tofuOutputs

	if path := cfg.TofuOutputsPath; path != "" {
		data, err := os.ReadFile(path)
		if err != nil {
			return outputs, err
		}
		if err := json.Unmarshal(data, &outputs); err != nil {
			return outputs, err
		}
		return outputs, nil
	}

	args := []string{"-chdir=" + cfg.TofuChdir, "output", "-json"}
	cmd := exec.CommandContext(context.Background(), "tofu", args...)
	cmd.Stderr = os.Stderr
	data, err := cmd.Output()
	if err != nil {
		return outputs, err
	}
	if err := json.Unmarshal(data, &outputs); err != nil {
		return outputs, err
	}
	return outputs, nil
}

func buildInventory(outputs tofuOutputs, opts inventoryOptions) (*inventory, error) {
	clusterName := cmp.Or(outputs.ClusterName.Value, defaultClusterName)
	if len(outputs.NodeIPv6Addresses.Value) == 0 {
		return nil, errors.New("node_ipv6_addresses output is empty")
	}

	sshPrivateKeyPath := cmp.Or(
		opts.SSHPrivateKeyPath,
		outputs.SSHPrivateKeyPath.Value,
		"~/.ssh/id_ed25519",
	)
	knownHostsPath, err := filepath.Abs(cmp.Or(opts.KnownHostsPath, defaultKnownHosts))
	if err != nil {
		return nil, fmt.Errorf("resolve known hosts path: %w", err)
	}

	inv := &inventory{
		Meta:          meta{Hostvars: map[string]hostvars{}},
		K3sNodes:      group{Hosts: []string{}},
		ControlPlanes: group{Hosts: []string{}},
		Workers:       group{Hosts: []string{}},
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
		case roleControlPlaneOnly, roleControlPlaneWorker:
			inv.ControlPlanes.Hosts = append(inv.ControlPlanes.Hosts, hostname)
		case roleWorker:
			inv.Workers.Hosts = append(inv.Workers.Hosts, hostname)
		case roleUnknown:
			return nil, fmt.Errorf("how did we hit role unknown! This should be impossible")
		}

		inv.Meta.Hostvars[hostname] = hostvars{
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

func inferredRole(nodeKey nodeKey) nodeRole {
	switch {
	case strings.HasPrefix(string(nodeKey), "cp-"):
		return roleControlPlaneWorker
	case strings.HasPrefix(string(nodeKey), "worker-"):
		return roleWorker
	default:
		return roleUnknown
	}
}

func (role nodeRole) valid() bool {
	switch role {
	case roleControlPlaneOnly, roleControlPlaneWorker, roleWorker:
		return true
	case roleUnknown:
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
