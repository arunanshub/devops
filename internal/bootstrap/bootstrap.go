// Package bootstrap encodes the clean-cluster build sequence documented in
// CLAUDE.md ("Bootstrap order") as ordered, guarded steps. The steps exec the
// same tools the Justfile recipes did (sops, helmfile, kubectl, tofu) — this
// package only adds ordering, guards, and resumability.
package bootstrap

import (
	"context"
	"fmt"
	"log/slog"
	"path/filepath"
	"strings"

	"github.com/arunanshub/devops/internal/execx"
	"github.com/arunanshub/devops/internal/logging"
)

// Config carries the paths and endpoints the steps need. Defaults live on
// the opsctl flags and match the Justfile exports.
type Config struct {
	// RepoRoot all paths resolve against.
	RepoRoot string
	// Kubeconfig path, exported to every command.
	Kubeconfig string
	// APIEndpoint is the in-cluster API address rendered into the Cilium
	// bootstrap values (K8S_API_ENDPOINT).
	APIEndpoint string
}

// Step is one bootstrap stage.
type Step struct {
	Name        string
	Description string
	Commands    []execx.Command
	// GuardRootApp refuses the step when the ArgoCD root Application
	// already exists: after the root app is applied, ArgoCD owns the
	// cluster, and re-running helmfile fights it for resource ownership.
	GuardRootApp bool
}

// RootAppName and RootAppNamespace identify the app-of-apps Application the
// guard checks for.
const (
	RootAppName      = "root"
	RootAppNamespace = "argocd"
)

// Steps returns the bootstrap sequence, in the only order that works.
func Steps(cfg Config) []Step {
	infra := filepath.Join(cfg.RepoRoot, "infra")
	k8sDir := filepath.Join(cfg.RepoRoot, "kubernetes")
	bootstrapDir := filepath.Join(k8sDir, "bootstrap")
	env := []string{
		"KUBECONFIG=" + cfg.Kubeconfig,
		"K8S_API_ENDPOINT=" + cfg.APIEndpoint,
		"LC_ALL=C.UTF-8",
		"LANG=C.UTF-8",
	}

	sopsApply := func(secretPath string) execx.Command {
		return execx.Command{
			Name: "bash",
			Args: []string{"-c", fmt.Sprintf("sops --decrypt %q | kubectl apply -f -", secretPath)},
			Env:  env,
		}
	}

	return []Step{
		{
			Name:        "tofu-apply",
			Description: "Provision Hetzner nodes, network, firewall, API LB; writes infra/kubeconfig.yaml",
			Commands: []execx.Command{
				{
					Name: "sops",
					Args: []string{
						"exec-env",
						filepath.Join(infra, "secrets.yaml"),
						"tofu apply",
					},
					Dir:         infra,
					Env:         env,
					Interactive: true,
				},
			},
		},
		{
			Name:         "hcloud-secret",
			Description:  "Apply the hcloud Secret so hccm can start",
			GuardRootApp: true,
			Commands: []execx.Command{
				sopsApply(filepath.Join(bootstrapDir, "secrets", "hcloud-ccm-secret.sops.yaml")),
			},
		},
		{
			Name:         "helmfile",
			Description:  "Install Gateway API CRDs + hccm + Cilium + ArgoCD (one-shot; ArgoCD adopts these releases)",
			GuardRootApp: true,
			Commands: []execx.Command{
				{Name: "helmfile", Args: []string{"deps"}, Dir: bootstrapDir, Env: env},
				{
					Name: "sops",
					Args: []string{
						"exec-env", filepath.Join(bootstrapDir, "secrets", "helmfile.secrets.yaml"),
						"helmfile apply",
					},
					Dir:         bootstrapDir,
					Env:         env,
					Interactive: true,
				},
			},
		},
		{
			Name:        "argocd-ssh",
			Description: "Apply the ArgoCD repo SSH key",
			Commands: []execx.Command{
				sopsApply(filepath.Join(bootstrapDir, "secrets", "argocd-repo-ssh.sops.yaml")),
			},
		},
		{
			Name:        "sealed-secrets-key",
			Description: "Restore the sealed-secrets master key BEFORE ArgoCD syncs any SealedSecret",
			Commands: []execx.Command{
				sopsApply(
					filepath.Join(bootstrapDir, "secrets", "sealed-secrets-master-key.sops.yaml"),
				),
				{
					Name: "kubectl",
					Args: []string{
						"rollout",
						"restart",
						"deployment",
						"sealed-secrets-controller",
						"-n",
						"kube-system",
					},
					Env: env,
				},
			},
		},
		{
			Name:        "root-app",
			Description: "Apply the root Application — ArgoCD takes ownership of the cluster from here",
			Commands: []execx.Command{{
				Name: "kubectl",
				Args: []string{"apply", "-f", filepath.Join(k8sDir, "root-application.yaml")},
				Env:  env,
			}},
		},
	}
}

// Options controls a Run.
type Options struct {
	// DryRun prints each step's commands without executing anything.
	DryRun bool
	// FromStep resumes at the named step (bootstrap is a sequence of
	// one-shots; a failure mid-way is resumed, not restarted).
	FromStep string
}

// Run executes the steps in order. rootAppExists is consulted once, before
// the first guarded step — a nil func skips the guard (dry-run without
// cluster access).
func Run(
	ctx context.Context,
	runner execx.Runner,
	steps []Step,
	rootAppExists func(context.Context) (bool, error),
	opts Options,
) error {
	start := 0
	if opts.FromStep != "" {
		idx := stepIndex(steps, opts.FromStep)
		if idx < 0 {
			return fmt.Errorf("unknown step %q (steps: %s)", opts.FromStep, stepNames(steps))
		}
		start = idx
	}

	guardChecked := false
	for _, step := range steps[start:] {
		ctx, end := logging.Span(ctx, "step."+step.Name)
		log := logging.FromContext(ctx)

		if step.GuardRootApp && !guardChecked && !opts.DryRun && rootAppExists != nil {
			exists, err := rootAppExists(ctx)
			if err != nil {
				end()
				return fmt.Errorf("check root Application before step %q: %w", step.Name, err)
			}
			if exists {
				end()
				return fmt.Errorf(
					"refusing step %q: the ArgoCD root Application %s/%s already exists — "+
						"ArgoCD owns the cluster now, and re-running bootstrap would fight it for "+
						"ownership of Cilium/hccm/ArgoCD resources (see CLAUDE.md). "+
						"If you really are rebuilding, the cluster should not have a root Application yet",
					step.Name, RootAppNamespace, RootAppName,
				)
			}
			guardChecked = true
		}

		log.InfoContext(ctx, "bootstrap step", slog.String("description", step.Description))
		for i := range step.Commands {
			command := &step.Commands[i]
			if opts.DryRun {
				log.InfoContext(ctx, "dry-run", slog.String("command", command.String()))
				continue
			}
			if err := runner.Run(ctx, command); err != nil {
				end()
				return fmt.Errorf("step %q failed (resume with --from-step %s): %w",
					step.Name, step.Name, err)
			}
		}
		end()
	}
	return nil
}

func stepIndex(steps []Step, name string) int {
	for i, s := range steps {
		if s.Name == name {
			return i
		}
	}
	return -1
}

func stepNames(steps []Step) string {
	names := make([]string, 0, len(steps))
	for _, s := range steps {
		names = append(names, s.Name)
	}
	return strings.Join(names, ", ")
}
