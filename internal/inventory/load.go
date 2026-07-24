package inventory

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"os/exec"

	"github.com/arunanshub/devops/internal/logging"
)

// Source says where tofu outputs come from.
type Source struct {
	// OutputsPath, when set, points at a JSON file containing `tofu output
	// -json` — used to avoid invoking tofu (e.g. in tests or CI).
	OutputsPath string
	// TofuChdir is passed as tofu's -chdir when OutputsPath is unset.
	TofuChdir string
}

// LoadOutputs reads tofu outputs from the file in src, or by running
// `tofu output -json` when no file is given.
func LoadOutputs(ctx context.Context, src Source) (TofuOutputs, error) {
	var outputs TofuOutputs

	data, err := readOutputs(ctx, src)
	if err != nil {
		return outputs, err
	}

	if err := json.Unmarshal(data, &outputs); err != nil {
		return outputs, fmt.Errorf("parse tofu outputs: %w", err)
	}
	return outputs, nil
}

func readOutputs(ctx context.Context, src Source) ([]byte, error) {
	if src.OutputsPath != "" {
		logging.FromContext(ctx).DebugContext(ctx, "reading tofu outputs from file",
			slog.String("path", src.OutputsPath))
		data, err := os.ReadFile(src.OutputsPath)
		if err != nil {
			return nil, fmt.Errorf("read tofu outputs file: %w", err)
		}
		return data, nil
	}

	logging.FromContext(ctx).DebugContext(ctx, "running tofu output -json",
		slog.String("chdir", src.TofuChdir))

	// tofu is a fixed binary and chdir comes from the operator's own
	// flag/env, not untrusted input.
	args := []string{"-chdir=" + src.TofuChdir, "output", "-json"}
	cmd := exec.CommandContext(ctx, "tofu", args...) //nolint:gosec // G204: see above

	cmd.Stderr = os.Stderr
	data, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("run tofu output -json: %w", err)
	}
	return data, nil
}
