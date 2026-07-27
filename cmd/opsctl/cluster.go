package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/arunanshub/devops/internal/adoption"
	"github.com/arunanshub/devops/internal/bootstrap"
	"github.com/arunanshub/devops/internal/execx"
	"github.com/arunanshub/devops/internal/k8s"
	"github.com/arunanshub/devops/internal/logging"
	"github.com/arunanshub/devops/internal/mtu"
)

// clusterCmd groups whole-cluster operations.
type clusterCmd struct {
	Bootstrap clusterBootstrapCmd `cmd:"" help:"Run the clean-cluster bootstrap sequence, in order, with guards."`
	Verify    clusterVerifyCmd    `cmd:"" help:"Verify cluster health: node readiness, adoption invariant, MTU stack."`
}

// clusterBootstrapCmd executes the 5-step bootstrap documented in CLAUDE.md.
// The helmfile steps refuse to run when the ArgoCD root Application already
// exists — after that point ArgoCD owns the cluster and re-running helmfile
// fights it for resource ownership.
type clusterBootstrapCmd struct {
	RepoRoot    string `default:"." type:"existingdir" help:"Repository root."`
	Kubeconfig  string `env:"KUBECONFIG" default:"infra/kubeconfig.yaml" help:"Kubeconfig path (written by tofu-apply)."`
	APIEndpoint string `env:"K8S_API_ENDPOINT" default:"10.0.0.100" help:"In-cluster API endpoint (the private API LB IP)."`
	DryRun      bool   `help:"Print the steps and commands without executing."`
	FromStep    string `help:"Resume from a named step after a mid-sequence failure."`
	ListSteps   bool   `help:"List step names and exit."`
}

func (c *clusterBootstrapCmd) Run(ctx context.Context) error {
	ctx, end := logging.Span(ctx, "cluster-bootstrap")
	defer end()

	steps := bootstrap.Steps(bootstrap.Config{
		RepoRoot:    c.RepoRoot,
		Kubeconfig:  c.Kubeconfig,
		APIEndpoint: c.APIEndpoint,
	})

	if c.ListSteps {
		for _, step := range steps {
			fmt.Printf("%-20s %s\n", step.Name, step.Description)
		}
		return nil
	}

	// The guard needs cluster access, but the cluster may not exist yet on
	// a clean build — resolve the checker lazily and treat an unreachable
	// or CRD-less cluster as "no root app".
	rootAppExists := func(ctx context.Context) (bool, error) {
		client, err := k8s.NewClient(c.Kubeconfig)
		if err != nil {
			return false, nil //nolint:nilerr // no kubeconfig yet = clean build
		}
		return client.HasApplication(ctx, bootstrap.RootAppNamespace, bootstrap.RootAppName)
	}

	return bootstrap.Run(ctx, execx.ExecRunner{}, steps, rootAppExists, bootstrap.Options{
		DryRun:   c.DryRun,
		FromStep: c.FromStep,
	})
}

// clusterVerifyCmd composes the post-change health checks: every node Ready,
// the helmfile→ArgoCD adoption invariant, and (optionally) the live MTU
// verification (which creates two short-lived test pods).
type clusterVerifyCmd struct {
	RepoRoot   string        `default:"." type:"existingdir" help:"Repository root."`
	Kubeconfig string        `env:"KUBECONFIG" required:"" type:"existingfile" help:"Path to kubeconfig."`
	Helmfile   string        `default:"kubernetes/bootstrap/helmfile.yaml" help:"Bootstrap helmfile path."`
	SkipMTU    bool          `help:"Skip the MTU verification (no test pods created)."`
	Timeout    time.Duration `default:"10m" help:"Overall timeout."`
}

func (c *clusterVerifyCmd) Run(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, c.Timeout)
	defer cancel()

	ctx, end := logging.Span(ctx, "cluster-verify")
	defer end()
	log := logging.FromContext(ctx)

	client, err := k8s.NewClient(c.Kubeconfig)
	if err != nil {
		return err
	}

	failed := false

	statuses, err := client.NodeStatuses(ctx)
	if err != nil {
		return err
	}
	for _, status := range statuses {
		if status.Ready {
			fmt.Printf("✓ node %s Ready\n", status.Name)
			continue
		}
		fmt.Printf("✗ node %s NotReady\n", status.Name)
		failed = true
	}

	findings, err := adoption.Verify(ctx, c.RepoRoot, c.Helmfile, adoptedReleases)
	if err != nil {
		return err
	}
	if len(findings) == 0 {
		fmt.Println("✓ helmfile→ArgoCD adoption invariant holds")
	} else {
		for _, finding := range findings {
			fmt.Println("✗ " + finding.String())
		}
		failed = true
	}

	if c.SkipMTU {
		log.InfoContext(ctx, "skipping MTU verification (--skip-mtu)")
	} else {
		cfg := mtu.DefaultConfig()
		verifier := mtu.NewVerifier(client, &cfg)
		report, err := verifier.Run(ctx)
		if err != nil {
			return err
		}
		report.Render(os.Stdout)
		if !report.Passed() {
			failed = true
		}
	}

	if failed {
		return errors.New("cluster verification failed")
	}
	log.InfoContext(ctx, "cluster verification passed", slog.Int("nodes", len(statuses)))
	return nil
}
