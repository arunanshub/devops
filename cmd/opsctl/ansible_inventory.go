package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"

	"github.com/arunanshub/devops/internal/inventory"
	"github.com/arunanshub/devops/internal/logging"
)

// ansibleInventoryCmd implements the Ansible dynamic-inventory contract
// (--list / --host) on top of tofu outputs. Ansible invokes it through the
// ansible/inventory/tofu_inventory shim.
type ansibleInventoryCmd struct {
	List bool   `xor:"mode" required:"" help:"Print the full inventory."`
	Host string `xor:"mode" required:"" help:"Print variables for one host."`

	TofuOutputs       string `env:"ANSIBLE_TOFU_OUTPUTS" help:"Path to a JSON file with tofu outputs (skips running tofu)."`
	TofuChdir         string `env:"TOFU_CHDIR" default:"infra" help:"Directory passed to tofu -chdir."`
	SSHPrivateKeyFile string `env:"ANSIBLE_SSH_PRIVATE_KEY_FILE" help:"Override the SSH private key path from tofu outputs."`
	KnownHostsFile    string `env:"ANSIBLE_KNOWN_HOSTS_FILE" default:"infra/.ssh_known_hosts" help:"SSH known-hosts file baked into ssh args."`
}

func (c *ansibleInventoryCmd) Run(ctx context.Context) error {
	ctx, end := logging.Span(ctx, "ansible-inventory")
	defer end()

	outputs, err := inventory.LoadOutputs(ctx, inventory.Source{
		OutputsPath: c.TofuOutputs,
		TofuChdir:   c.TofuChdir,
	})
	if err != nil {
		return fmt.Errorf("load tofu outputs: %w", err)
	}

	inv, err := inventory.Build(outputs, inventory.Options{
		SSHPrivateKeyPath: c.SSHPrivateKeyFile,
		KnownHostsPath:    c.KnownHostsFile,
	})
	if err != nil {
		return fmt.Errorf("build inventory: %w", err)
	}
	logging.FromContext(ctx).DebugContext(ctx, "built inventory",
		slog.Int("hosts", len(inv.Meta.Hostvars)),
		slog.Int("control_planes", len(inv.ControlPlanes.Hosts)),
		slog.Int("workers", len(inv.Workers.Hosts)))

	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")

	if c.Host != "" {
		hostvars, ok := inv.Meta.Hostvars[c.Host]
		if !ok {
			return encoder.Encode(map[string]any{})
		}
		return encoder.Encode(hostvars)
	}
	return encoder.Encode(inv)
}
