package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/arunanshub/devops/internal/k8s"
	"github.com/arunanshub/devops/internal/logging"
	"github.com/arunanshub/devops/internal/nodecfg"
)

// verifyKubeletConfigCmd asserts that a node's LIVE kubelet configuration
// (/configz) matches the kubelet-args declared under nodes/. This is the
// post-restart gate k3s-config.yml calls per node — it talks to the kubelet
// directly, because the node Ready condition can stay stale-True for the
// ~40s node-monitor grace period after a kubelet dies (2026-07-25 game day).
type verifyKubeletConfigCmd struct {
	Node       string        `arg:"" help:"Node name (e.g. hetzner-k3s-cp-1)."`
	Role       string        `arg:"" help:"Declared node role."                       enum:"cp_only,cp_worker,worker"`
	Dir        string        `       help:"Root of the declarative node config tree."                                 default:"nodes" type:"existingdir"`
	Kubeconfig string        `       help:"Path to kubeconfig."                                                                       type:"existingfile" env:"KUBECONFIG" required:""`
	Timeout    time.Duration `       help:"Overall timeout."                                                          default:"30s"`
}

func (c *verifyKubeletConfigCmd) Run(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, c.Timeout)
	defer cancel()

	ctx, end := logging.Span(ctx, "verify-kubelet-config", slog.String("node", c.Node))
	defer end()

	declared, err := nodecfg.DeclaredKubeletArgs(c.Dir, c.Role)
	if err != nil {
		return err
	}

	client, err := k8s.NewClient(c.Kubeconfig)
	if err != nil {
		return err
	}
	configz, err := client.NodeConfigz(ctx, c.Node)
	if err != nil {
		return err
	}

	findings, err := nodecfg.VerifyKubeletConfig(declared, configz)
	if err != nil {
		return err
	}

	if len(findings) == 0 {
		logging.FromContext(ctx).InfoContext(ctx, "kubelet runtime config matches declared state",
			slog.Int("declared_args", len(declared)))
		return nil
	}

	for _, finding := range findings {
		fmt.Println("✗ " + finding.Problem)
	}
	return errors.New("kubelet runtime config does not match declared state")
}
