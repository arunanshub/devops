package main

import (
	"context"
	"fmt"

	"github.com/arunanshub/devops/internal/bootstrap"
	"github.com/arunanshub/devops/internal/execx"
	"github.com/arunanshub/devops/internal/k8s"
	"github.com/arunanshub/devops/internal/logging"
)

// clusterCmd groups whole-cluster operations.
type clusterCmd struct {
	Bootstrap clusterBootstrapCmd `cmd:"" help:"Run the clean-cluster bootstrap sequence, in order, with guards."`
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
