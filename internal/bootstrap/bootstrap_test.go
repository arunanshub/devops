package bootstrap

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/arunanshub/devops/internal/execx"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type fakeRunner struct {
	commands []execx.Command
	failOn   string
}

func (f *fakeRunner) Run(_ context.Context, c *execx.Command) error {
	f.commands = append(f.commands, *c)
	if f.failOn != "" && strings.Contains(c.String(), f.failOn) {
		return fmt.Errorf("boom: %s", c.String())
	}
	return nil
}

func (f *fakeRunner) Output(_ context.Context, c *execx.Command) (string, error) {
	f.commands = append(f.commands, *c)
	return "", nil
}

func testConfig() Config {
	return Config{
		RepoRoot:    "/repo",
		Kubeconfig:  "/repo/infra/kubeconfig.yaml",
		APIEndpoint: "10.0.0.100",
	}
}

func rootApp(exists bool) func(context.Context) (bool, error) {
	return func(context.Context) (bool, error) { return exists, nil }
}

func TestRunExecutesAllStepsInOrder(t *testing.T) {
	runner := &fakeRunner{}
	steps := Steps(testConfig())

	err := Run(t.Context(), runner, steps, rootApp(false), Options{})
	require.NoError(t, err)

	var total int
	for _, s := range steps {
		total += len(s.Commands)
	}
	require.Len(t, runner.commands, total)
	// First command provisions, last applies the root Application.
	assert.Contains(t, runner.commands[0].String(), "tofu apply")
	assert.Contains(t, runner.commands[len(runner.commands)-1].String(), "root-application.yaml")
}

func TestRunRefusesWhenRootAppExists(t *testing.T) {
	runner := &fakeRunner{}
	steps := Steps(testConfig())

	err := Run(t.Context(), runner, steps, rootApp(true), Options{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "refusing")
	// Only the unguarded tofu-apply step ran before the guard fired.
	require.Len(t, runner.commands, 1)
	assert.Contains(t, runner.commands[0].String(), "tofu apply")
}

func TestRunFromStepResumes(t *testing.T) {
	runner := &fakeRunner{}
	steps := Steps(testConfig())

	err := Run(t.Context(), runner, steps, rootApp(false), Options{FromStep: "argocd-ssh"})
	require.NoError(t, err)

	// argocd-ssh (1) + sealed-secrets-key (2) + root-app (1).
	require.Len(t, runner.commands, 4)
	assert.Contains(t, runner.commands[0].String(), "argocd-repo-ssh")
}

func TestRunUnknownStepErrors(t *testing.T) {
	err := Run(
		t.Context(),
		&fakeRunner{},
		Steps(testConfig()),
		rootApp(false),
		Options{FromStep: "nope"},
	)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "unknown step")
}

func TestRunDryRunExecutesNothing(t *testing.T) {
	runner := &fakeRunner{}
	err := Run(t.Context(), runner, Steps(testConfig()), nil, Options{DryRun: true})
	require.NoError(t, err)
	assert.Empty(t, runner.commands)
}

func TestRunStepFailureNamesResumePoint(t *testing.T) {
	runner := &fakeRunner{failOn: "helmfile apply"}
	err := Run(t.Context(), runner, Steps(testConfig()), rootApp(false), Options{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--from-step helmfile")
}
