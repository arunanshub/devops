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
	return []Step{
		tofuApplyStep(cfg),
		hcloudSecretStep(cfg),
		helmfileStep(cfg),
		argocdSSHStep(cfg),
		sealedSecretsKeyStep(cfg),
		rootAppStep(cfg),
	}
}

// commandEnv is the environment every bootstrap command runs with.
func commandEnv(cfg Config) []string {
	return []string{
		"KUBECONFIG=" + cfg.Kubeconfig,
		"K8S_API_ENDPOINT=" + cfg.APIEndpoint,
		"LC_ALL=C.UTF-8",
		"LANG=C.UTF-8",
	}
}

func bootstrapDir(cfg Config) string {
	return filepath.Join(cfg.RepoRoot, "kubernetes", "bootstrap")
}

func secretPath(cfg Config, name string) string {
	return filepath.Join(bootstrapDir(cfg), "secrets", name)
}

// sopsApply decrypts a SOPS secret and pipes it into kubectl apply.
func sopsApply(cfg Config, secret string) execx.Command {
	return execx.Command{
		Name: "bash",
		Args: []string{"-c", fmt.Sprintf("sops --decrypt %q | kubectl apply -f -", secret)},
		Env:  commandEnv(cfg),
	}
}

func tofuApplyStep(cfg Config) Step {
	infra := filepath.Join(cfg.RepoRoot, "infra")
	return Step{
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
				Env:         commandEnv(cfg),
				Interactive: true,
			},
		},
	}
}

func hcloudSecretStep(cfg Config) Step {
	return Step{
		Name:         "hcloud-secret",
		Description:  "Apply the hcloud Secret so hccm can start",
		GuardRootApp: true,
		Commands: []execx.Command{
			sopsApply(cfg, secretPath(cfg, "hcloud-ccm-secret.sops.yaml")),
		},
	}
}

func helmfileStep(cfg Config) Step {
	return Step{
		Name:         "helmfile",
		Description:  "Install Gateway API CRDs + hccm + Cilium + ArgoCD (one-shot; ArgoCD adopts these releases)",
		GuardRootApp: true,
		Commands: []execx.Command{
			{Name: "helmfile", Args: []string{"deps"}, Dir: bootstrapDir(cfg), Env: commandEnv(cfg)},
			{
				Name: "sops",
				Args: []string{
					"exec-env", secretPath(cfg, "helmfile.secrets.yaml"),
					"helmfile apply",
				},
				Dir:         bootstrapDir(cfg),
				Env:         commandEnv(cfg),
				Interactive: true,
			},
		},
	}
}

func argocdSSHStep(cfg Config) Step {
	return Step{
		Name:        "argocd-ssh",
		Description: "Apply the ArgoCD repo SSH key",
		Commands: []execx.Command{
			sopsApply(cfg, secretPath(cfg, "argocd-repo-ssh.sops.yaml")),
		},
	}
}

func sealedSecretsKeyStep(cfg Config) Step {
	return Step{
		Name:        "sealed-secrets-key",
		Description: "Restore the sealed-secrets master key BEFORE ArgoCD syncs any SealedSecret",
		Commands: []execx.Command{
			sopsApply(cfg, secretPath(cfg, "sealed-secrets-master-key.sops.yaml")),
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
				Env: commandEnv(cfg),
			},
		},
	}
}

func rootAppStep(cfg Config) Step {
	return Step{
		Name:        "root-app",
		Description: "Apply the root Application — ArgoCD takes ownership of the cluster from here",
		Commands: []execx.Command{{
			Name: "kubectl",
			Args: []string{
				"apply", "-f",
				filepath.Join(cfg.RepoRoot, "kubernetes", "root-application.yaml"),
			},
			Env: commandEnv(cfg),
		}},
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
	start, err := startIndex(steps, opts.FromStep)
	if err != nil {
		return err
	}

	guardChecked := false
	for _, step := range steps[start:] {
		ctx, end := logging.Span(ctx, "step."+step.Name)

		if step.GuardRootApp && !guardChecked && !opts.DryRun && rootAppExists != nil {
			if err := guardAgainstRootApp(ctx, rootAppExists, step.Name); err != nil {
				end()
				return err
			}
			guardChecked = true
		}

		err := runStep(ctx, runner, step, opts.DryRun)
		end()
		if err != nil {
			return err
		}
	}
	return nil
}

// startIndex resolves the resume point: index 0, or the named step.
func startIndex(steps []Step, fromStep string) (int, error) {
	if fromStep == "" {
		return 0, nil
	}
	idx := stepIndex(steps, fromStep)
	if idx < 0 {
		return 0, fmt.Errorf("unknown step %q (steps: %s)", fromStep, stepNames(steps))
	}
	return idx, nil
}

// guardAgainstRootApp fails when the ArgoCD root Application already exists —
// past that point ArgoCD owns the cluster and re-running bootstrap fights it.
func guardAgainstRootApp(
	ctx context.Context,
	rootAppExists func(context.Context) (bool, error),
	stepName string,
) error {
	exists, err := rootAppExists(ctx)
	if err != nil {
		return fmt.Errorf("check root Application before step %q: %w", stepName, err)
	}
	if exists {
		return fmt.Errorf(
			"refusing step %q: the ArgoCD root Application %s/%s already exists — "+
				"ArgoCD owns the cluster now, and re-running bootstrap would fight it for "+
				"ownership of Cilium/hccm/ArgoCD resources (see CLAUDE.md). "+
				"If you really are rebuilding, the cluster should not have a root Application yet",
			stepName, RootAppNamespace, RootAppName,
		)
	}
	return nil
}

// runStep executes (or dry-run prints) every command of one step.
func runStep(ctx context.Context, runner execx.Runner, step Step, dryRun bool) error {
	log := logging.FromContext(ctx)
	log.InfoContext(ctx, "bootstrap step", slog.String("description", step.Description))
	for i := range step.Commands {
		command := &step.Commands[i]
		if dryRun {
			log.InfoContext(ctx, "dry-run", slog.String("command", command.String()))
			continue
		}
		if err := runner.Run(ctx, command); err != nil {
			return fmt.Errorf("step %q failed (resume with --from-step %s): %w",
				step.Name, step.Name, err)
		}
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
