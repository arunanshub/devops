package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"

	"github.com/arunanshub/devops/internal/adoption"
	"github.com/arunanshub/devops/internal/logging"
)

// adoptedReleases declares every release installed by the bootstrap helmfile
// and later adopted by an ArgoCD Application. New helmfile→ArgoCD adoptions
// must be added here so CI keeps guarding the invariant.
var adoptedReleases = []adoption.Pair{
	{
		Release: "cilium",
		AppPath: "kubernetes/base/infra/cilium/application.yaml",
		// ArgoCD-only by necessity: ServiceMonitors need the monitoring CRDs
		// and the dashboards ConfigMaps need the monitoring namespace, neither
		// of which exists at bootstrap time. The cilium chart does NOT
		// capability-gate these (verified against v1.20.0-pre.4 templates), so
		// including them in bootstrap values would fail the helmfile install.
		IgnorePaths: []string{
			"prometheus.serviceMonitor",
			"operator.prometheus.serviceMonitor",
			"hubble.metrics.serviceMonitor",
			"hubble.metrics.dashboards",
		},
	},
	{
		Release: "hccm",
		AppPath: "kubernetes/components/hcloud-ccm/application.yaml",
	},
	{
		Release: "argocd",
		AppPath: "kubernetes/base/infra/argocd/application.yaml",
		// The initial admin password hash is a bootstrap-only overlay
		// (values/bootstrap.yaml.gotmpl); ArgoCD does not manage it.
		IgnorePaths: []string{"configs.secret.argocdServerAdminPassword"},
	},
}

// verifyAdoptionCmd checks that helmfile-installed releases and their
// adopting ArgoCD Applications agree on chart version, release name, and
// rendered values — the invariants that make adoption a no-op diff under
// ServerSideApply (see CLAUDE.md "Helmfile→ArgoCD adoption").
type verifyAdoptionCmd struct {
	RepoRoot string `default:"."                                  help:"Repository root all paths resolve against." type:"existingdir"`
	Helmfile string `default:"kubernetes/bootstrap/helmfile.yaml" help:"Repo-relative bootstrap helmfile path."`
}

func (c *verifyAdoptionCmd) Run(ctx context.Context) error {
	ctx, end := logging.Span(ctx, "verify-adoption")
	defer end()

	findings, err := adoption.Verify(ctx, c.RepoRoot, c.Helmfile, adoptedReleases)
	if err != nil {
		return err
	}

	if len(findings) == 0 {
		logging.FromContext(ctx).InfoContext(ctx, "adoption invariant holds",
			slog.Int("releases", len(adoptedReleases)))
		return nil
	}

	for _, finding := range findings {
		fmt.Println("✗ " + finding.String())
	}
	return errors.New("helmfile→ArgoCD adoption invariant violated")
}
