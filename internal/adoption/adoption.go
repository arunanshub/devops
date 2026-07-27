// Package adoption verifies the helmfile→ArgoCD adoption invariant: for
// every release installed by kubernetes/bootstrap/helmfile.yaml and later
// adopted by an ArgoCD Application under ServerSideApply, the two
// definitions must agree, or the adoption stops being a no-op diff:
//
//   - the helmfile chart version must equal the Application targetRevision
//   - the helmfile release name must equal helm.releaseName (Helm derives
//     the immutable app.kubernetes.io/instance selector label from it — a
//     mismatch is a permanent reconcile failure)
//   - the bootstrap values must render to the same effective values as the
//     ArgoCD values file
package adoption

import (
	"context"
	"fmt"
	"log/slog"
	"strings"

	"github.com/google/go-cmp/cmp"
	"github.com/google/go-cmp/cmp/cmpopts"

	"github.com/arunanshub/devops/internal/logging"
)

// Pair declares one adopted release to verify.
type Pair struct {
	// Release is the helmfile release name, which must also be the
	// Application's helm.releaseName.
	Release string
	// AppPath is the repo-relative path to the ArgoCD Application manifest.
	AppPath string
	// IgnorePaths are dotted value paths excluded from the comparison —
	// bootstrap-only overlays that ArgoCD deliberately does not manage
	// (e.g. the initial admin password hash).
	IgnorePaths []string
}

// Finding is one detected invariant violation.
type Finding struct {
	Release string
	Problem string
}

func (f Finding) String() string {
	return f.Release + ": " + f.Problem
}

// Verify checks every pair against the helmfile at helmfilePath. Repo-relative
// paths are resolved against repoRoot. It returns one finding per violation;
// an empty slice means the invariant holds.
func Verify(ctx context.Context, repoRoot, helmfilePath string, pairs []Pair) ([]Finding, error) {
	helmfile, err := loadHelmfile(repoRoot, helmfilePath)
	if err != nil {
		return nil, err
	}

	var findings []Finding
	for _, pair := range pairs {
		pairFindings, err := verifyPair(ctx, repoRoot, helmfile, pair)
		if err != nil {
			return nil, fmt.Errorf("verify release %q: %w", pair.Release, err)
		}
		findings = append(findings, pairFindings...)
	}
	return findings, nil
}

func verifyPair(
	ctx context.Context,
	repoRoot string,
	helmfile *helmfileSpec,
	pair Pair,
) ([]Finding, error) {
	release, ok := helmfile.release(pair.Release)
	if !ok {
		return nil, fmt.Errorf("release not found in %s", helmfile.path)
	}

	app, err := loadApplication(repoRoot, pair.AppPath)
	if err != nil {
		return nil, err
	}

	findings := pinFindings(pair, &release, app)

	drift, err := valuesDrift(ctx, repoRoot, pair, &release, app)
	if err != nil {
		return nil, err
	}
	findings = append(findings, drift...)

	if len(findings) > 0 {
		findings = append(findings, Finding{
			Release: pair.Release,
			Problem: fmt.Sprintf(
				"fix by syncing the bootstrap side (%s) to the ArgoCD side (%s) — "+
					"bootstrap files have no runtime effect until the next cluster build",
				strings.Join(release.Values, ", "),
				strings.Join(app.ValueFiles, ", "),
			),
		})
	}
	return findings, nil
}

// pinFindings checks the two identity pins: chart version and release name.
func pinFindings(pair Pair, release *helmfileRelease, app *appSpec) []Finding {
	var findings []Finding
	fail := func(format string, args ...any) {
		findings = append(
			findings,
			Finding{Release: pair.Release, Problem: fmt.Sprintf(format, args...)},
		)
	}

	if release.Version != app.TargetRevision {
		fail("chart version drift: helmfile has %q, Application targetRevision is %q",
			release.Version, app.TargetRevision)
	}
	if pair.Release != app.ReleaseName {
		fail("releaseName mismatch: helmfile release is %q, Application helm.releaseName is %q — "+
			"the app.kubernetes.io/instance selector label is immutable, adoption will permanently fail",
			pair.Release, app.ReleaseName)
	}
	return findings
}

// valuesDrift renders both value sets, strips the deliberately-unmanaged
// paths, and reports any remaining difference.
func valuesDrift(
	ctx context.Context,
	repoRoot string,
	pair Pair,
	release *helmfileRelease,
	app *appSpec,
) ([]Finding, error) {
	bootstrapValues, err := release.renderValues()
	if err != nil {
		return nil, fmt.Errorf("render bootstrap values: %w", err)
	}
	argocdValues, err := app.loadValues(repoRoot)
	if err != nil {
		return nil, fmt.Errorf("load ArgoCD values: %w", err)
	}

	for _, path := range pair.IgnorePaths {
		deletePath(bootstrapValues, path)
		deletePath(argocdValues, path)
	}
	pruneEmpty(bootstrapValues)
	pruneEmpty(argocdValues)

	diff := cmp.Diff(bootstrapValues, argocdValues, cmpopts.EquateEmpty())
	logging.FromContext(ctx).DebugContext(ctx, "compared values",
		slog.String("release", pair.Release), slog.Bool("drifted", diff != ""))
	if diff == "" {
		return nil, nil
	}
	return []Finding{{
		Release: pair.Release,
		Problem: fmt.Sprintf("values drift (-bootstrap +argocd):\n%s", diff),
	}}, nil
}
