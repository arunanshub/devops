// Package execx runs the external tools opsctl orchestrates (tofu, sops,
// helmfile, kubectl, ansible-playbook). opsctl adds ordering, guards, and
// gates on top of those tools — it never reimplements them.
package execx

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"strings"

	"github.com/arunanshub/devops/internal/logging"
)

// Command is one external command invocation.
type Command struct {
	// Name is the binary; Args are its arguments.
	Name string
	Args []string
	// Dir is the working directory ("" = inherit).
	Dir string
	// Env entries are appended to the inherited environment.
	Env []string
	// Interactive attaches the user's stdin — required for tools that
	// prompt, like `tofu apply`.
	Interactive bool
}

func (c *Command) String() string {
	parts := append([]string{c.Name}, c.Args...)
	return strings.Join(parts, " ")
}

// Runner executes external commands. The fake implementation in tests
// records invocations instead of executing them.
type Runner interface {
	// Run streams the command's output to the terminal and fails on
	// non-zero exit.
	Run(ctx context.Context, c *Command) error
	// Output captures stdout (stderr streams through) for commands whose
	// result feeds a decision.
	Output(ctx context.Context, c *Command) (string, error)
}

// ExecRunner runs commands for real.
type ExecRunner struct{}

func (ExecRunner) Run(ctx context.Context, c *Command) error {
	cmd := build(ctx, c)
	cmd.Stdout = os.Stdout
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("run %q: %w", c.String(), err)
	}
	return nil
}

func (ExecRunner) Output(ctx context.Context, c *Command) (string, error) {
	cmd := build(ctx, c)
	out, err := cmd.Output()
	if err != nil {
		return string(out), fmt.Errorf("run %q: %w", c.String(), err)
	}
	return string(out), nil
}

func build(ctx context.Context, c *Command) *exec.Cmd {
	logging.FromContext(ctx).InfoContext(ctx, "exec", slog.String("command", c.String()))

	// The command list is assembled from opsctl's own step definitions and
	// operator flags, not untrusted input.
	cmd := exec.CommandContext(ctx, c.Name, c.Args...) //nolint:gosec // G204: see above
	cmd.Dir = c.Dir
	cmd.Env = append(os.Environ(), c.Env...)
	cmd.Stderr = os.Stderr
	if c.Interactive {
		cmd.Stdin = os.Stdin
	}
	return cmd
}
