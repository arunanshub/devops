package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"

	"github.com/arunanshub/devops/internal/logging"
	"github.com/arunanshub/devops/internal/nodecfg"
)

// verifyNodeConfigCmd validates the declarative node config under nodes/
// against the REAL flag schemas of the pinned k3s and kubelet binaries.
// A key that isn't a flag crash-loops k3s at startup and is invisible to
// every YAML-level check — this is the plan-time schema validation the
// node-config layer otherwise lacks.
type verifyNodeConfigCmd struct {
	Dir        string `default:"nodes"                                                       help:"Root of the declarative node config tree." type:"existingdir"`
	LocalsPath string `default:"infra/locals.tf"                                             help:"File carrying the k3s_version pin."`
	K3sVersion string `help:"Override the k3s version (default: parsed from --locals-path)."`
	CacheDir   string `help:"Binary cache directory (default: ~/.cache/opsctl)."`
}

func (c *verifyNodeConfigCmd) Run(ctx context.Context) error {
	ctx, end := logging.Span(ctx, "verify-node-config")
	defer end()

	version, err := c.resolveVersion()
	if err != nil {
		return err
	}

	k3sFlags, kubeletFlags, err := c.loadFlagSchemas(ctx, version)
	if err != nil {
		return err
	}

	findings, err := nodecfg.ValidateConfigDir(c.Dir, k3sFlags, kubeletFlags)
	if err != nil {
		return err
	}

	if len(findings) == 0 {
		logging.FromContext(ctx).InfoContext(ctx, "node config valid against pinned binaries",
			slog.String("k3s", version),
			slog.Int("k3s_flags", len(k3sFlags)),
			slog.Int("kubelet_flags", len(kubeletFlags)))
		return nil
	}

	for _, finding := range findings {
		fmt.Println("✗ " + finding.String())
	}
	return errors.New("node config failed schema validation")
}

// resolveVersion returns the k3s version override or the pin parsed from
// --locals-path.
func (c *verifyNodeConfigCmd) resolveVersion() (string, error) {
	if c.K3sVersion != "" {
		return c.K3sVersion, nil
	}
	return nodecfg.K3sVersionFromLocals(c.LocalsPath)
}

// resolveCacheDir returns the binary cache directory, defaulting to
// ~/.cache/opsctl.
func (c *verifyNodeConfigCmd) resolveCacheDir() (string, error) {
	if c.CacheDir != "" {
		return c.CacheDir, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home for cache dir: %w", err)
	}
	return filepath.Join(home, ".cache", "opsctl"), nil
}

// loadFlagSchemas downloads (or reuses) the pinned binaries and parses their
// real flag schemas from --help output.
func (c *verifyNodeConfigCmd) loadFlagSchemas(
	ctx context.Context,
	version string,
) (k3sFlags, kubeletFlags nodecfg.FlagSet, err error) {
	cacheDir, err := c.resolveCacheDir()
	if err != nil {
		return nil, nil, err
	}

	binaries, err := nodecfg.EnsureBinaries(ctx, cacheDir, version)
	if err != nil {
		return nil, nil, err
	}

	serverHelp, err := nodecfg.HelpText(ctx, binaries.K3s, "server", "--help")
	if err != nil {
		return nil, nil, err
	}
	kubeletHelp, err := nodecfg.HelpText(ctx, binaries.Kubelet, "--help")
	if err != nil {
		return nil, nil, err
	}

	k3sFlags = nodecfg.ParseHelpFlags(serverHelp)
	kubeletFlags = nodecfg.ParseHelpFlags(kubeletHelp)
	if len(k3sFlags) == 0 || len(kubeletFlags) == 0 {
		return nil, nil, errors.New(
			"parsed an empty flag schema — help output format may have changed")
	}
	return k3sFlags, kubeletFlags, nil
}
