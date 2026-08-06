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
	RepoRoot    string `default:"."                                                   help:"Repository root." type:"existingdir"`
	Kubeconfig  string `default:"infra/kubeconfig.yaml"                               env:"KUBECONFIG"        help:"Kubeconfig path (written by tofu-apply)."`
	APIEndpoint string `default:"10.0.0.100"                                          env:"K8S_API_ENDPOINT"  help:"In-cluster API endpoint (the private API LB IP)."`
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
	RepoRoot   string        `default:"."                                              help:"Repository root."         type:"existingdir"`
	Kubeconfig string        `env:"KUBECONFIG"                                         help:"Path to kubeconfig."      required:""        type:"existingfile"`
	Helmfile   string        `default:"kubernetes/bootstrap/helmfile.yaml"             help:"Bootstrap helmfile path."`
	SkipMTU    bool          `help:"Skip the MTU verification (no test pods created)."`
	Timeout    time.Duration `default:"10m"                                            help:"Overall timeout."`
}

func (c *clusterVerifyCmd) Run(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, c.Timeout)
	defer cancel()

	ctx, end := logging.Span(ctx, "cluster-verify")
	defer end()

	client, err := k8s.NewClient(c.Kubeconfig)
	if err != nil {
		return err
	}

	nodesOK, nodeCount, err := verifyNodesReady(ctx, client)
	if err != nil {
		return err
	}
	adoptionOK, err := c.verifyAdoption(ctx)
	if err != nil {
		return err
	}
	mtuOK, err := c.verifyMTU(ctx, client)
	if err != nil {
		return err
	}

	if !nodesOK || !adoptionOK || !mtuOK {
		return errors.New("cluster verification failed")
	}
	logging.FromContext(ctx).InfoContext(ctx, "cluster verification passed",
		slog.Int("nodes", nodeCount))
	return nil
}

// verifyNodesReady prints per-node readiness and reports whether every node
// is Ready.
func verifyNodesReady(ctx context.Context, client *k8s.Client) (ok bool, nodes int, err error) {
	statuses, err := client.NodeStatuses(ctx)
	if err != nil {
		return false, 0, err
	}
	ok = true
	for _, status := range statuses {
		if status.Ready {
			fmt.Printf("✓ node %s Ready\n", status.Name)
			continue
		}
		fmt.Printf("✗ node %s NotReady\n", status.Name)
		ok = false
	}
	return ok, len(statuses), nil
}

// verifyAdoption checks the helmfile→ArgoCD adoption invariant and prints
// every finding.
func (c *clusterVerifyCmd) verifyAdoption(ctx context.Context) (bool, error) {
	findings, err := adoption.Verify(ctx, c.RepoRoot, c.Helmfile, adoptedReleases)
	if err != nil {
		return false, err
	}
	if len(findings) == 0 {
		fmt.Println("✓ helmfile→ArgoCD adoption invariant holds")
		return true, nil
	}
	for _, finding := range findings {
		fmt.Println("✗ " + finding.String())
	}
	return false, nil
}

// verifyMTU runs the live MTU verification unless --skip-mtu was given.
func (c *clusterVerifyCmd) verifyMTU(ctx context.Context, client *k8s.Client) (bool, error) {
	if c.SkipMTU {
		logging.FromContext(ctx).InfoContext(ctx, "skipping MTU verification (--skip-mtu)")
		return true, nil
	}
	cfg := mtu.DefaultConfig()
	verifier := mtu.NewVerifier(client, &cfg)
	report, err := verifier.Run(ctx)
	if err != nil {
		return false, err
	}
	report.Render(os.Stdout)
	return report.Passed(), nil
}
