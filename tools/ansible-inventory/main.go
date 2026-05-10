package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"

	"github.com/caarlos0/env/v11"
)

const (
	defaultClusterName = "hetzner-k3s"
	defaultTofuChdir   = "infra"
)

type output[T any] struct {
	Value T `json:"value"`
}

type nodeKey string
type ipv6Address string
type privateIP string
type nodeRole string

const (
	roleControlPlaneOnly   nodeRole = "cp_only"
	roleControlPlaneWorker nodeRole = "cp_worker"
	roleWorker             nodeRole = "worker"
	roleUnknown            nodeRole = "unknown"
)

type nodeIPv6Addresses map[nodeKey]ipv6Address
type nodePrivateIPs map[nodeKey]privateIP
type nodeRoles map[nodeKey]nodeRole

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
	RepoRoot              string
	SSHPrivateKeyOverride string
}

type config struct {
	TofuOutputsPath       string `env:"ANSIBLE_TOFU_OUTPUTS"`
	TofuChdir             string `env:"TOFU_CHDIR"`
	SSHPrivateKeyOverride string `env:"ANSIBLE_SSH_PRIVATE_KEY_FILE"`
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
		RepoRoot:              repoRoot(),
		SSHPrivateKeyOverride: cfg.SSHPrivateKeyOverride,
	})
	if err != nil {
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

	tofuChdir := cfg.TofuChdir
	if tofuChdir == "" {
		tofuChdir = filepath.Join(repoRoot(), defaultTofuChdir)
	}

	cmd := exec.Command("tofu", "-chdir="+tofuChdir, "output", "-json")
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

func buildInventory(outputs tofuOutputs, opts inventoryOptions) (inventory, error) {
	clusterName := outputs.ClusterName.Value
	if clusterName == "" {
		clusterName = defaultClusterName
	}
	if len(outputs.NodeIPv6Addresses.Value) == 0 {
		return inventory{}, errors.New("node_ipv6_addresses output is empty")
	}

	sshPrivateKeyPath := opts.SSHPrivateKeyOverride
	if sshPrivateKeyPath == "" {
		sshPrivateKeyPath = outputs.SSHPrivateKeyPath.Value
	}
	if sshPrivateKeyPath == "" {
		sshPrivateKeyPath = "~/.ssh/id_ed25519"
	}

	inv := inventory{
		Meta:          meta{Hostvars: map[string]hostvars{}},
		K3sNodes:      group{Hosts: []string{}},
		ControlPlanes: group{Hosts: []string{}},
		Workers:       group{Hosts: []string{}},
	}

	nodeKeys := sortedKeys(outputs.NodeIPv6Addresses.Value)
	for _, nodeKey := range nodeKeys {
		hostname := clusterName + "-" + string(nodeKey)
		role := outputs.NodeRoles.Value[nodeKey]
		if role == "" {
			role = inferredRole(nodeKey)
		}
		if !role.valid() {
			return inventory{}, fmt.Errorf("node %q has unsupported role %q", nodeKey, role)
		}

		nodePrivateIP, ok := outputs.NodePrivateIPs.Value[nodeKey]
		if !ok || nodePrivateIP == "" {
			return inventory{}, fmt.Errorf("node %q is missing node_private_ips output", nodeKey)
		}

		inv.K3sNodes.Hosts = append(inv.K3sNodes.Hosts, hostname)
		switch role {
		case roleControlPlaneOnly, roleControlPlaneWorker:
			inv.ControlPlanes.Hosts = append(inv.ControlPlanes.Hosts, hostname)
		case roleWorker:
			inv.Workers.Hosts = append(inv.Workers.Hosts, hostname)
		}

		inv.Meta.Hostvars[hostname] = hostvars{
			AnsibleHost:           string(outputs.NodeIPv6Addresses.Value[nodeKey]),
			AnsibleUser:           "root",
			AnsiblePrivateKeyFile: expandHome(sshPrivateKeyPath),
			AnsibleSSHCommonArgs:  sshCommonArgs(opts.RepoRoot),
			NodeKey:               string(nodeKey),
			NodeRole:              string(role),
			NodePrivateIP:         string(nodePrivateIP),
			KubernetesNodeName:    hostname,
			APILBPrivateIP:        outputs.APILBPrivateIP.Value,
		}
	}

	return inv, nil
}

func sortedKeys(values nodeIPv6Addresses) []nodeKey {
	keys := make([]nodeKey, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	return keys
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
	default:
		return false
	}
}

func sshCommonArgs(repoRootPath string) string {
	if repoRootPath == "" {
		repoRootPath = repoRoot()
	}
	knownHosts := filepath.Join(repoRootPath, "infra", ".ssh_known_hosts")
	return "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=" + knownHosts
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

func repoRoot() string {
	wd, err := os.Getwd()
	if err != nil {
		return "."
	}
	root, err := findUp(wd, "go.mod")
	if err != nil {
		return wd
	}
	return root
}

func findUp(start string, marker string) (string, error) {
	current := start
	for {
		if _, err := os.Stat(filepath.Join(current, marker)); err == nil {
			return current, nil
		}
		parent := filepath.Dir(current)
		if parent == current {
			return "", errors.New("repo root not found")
		}
		current = parent
	}
}
