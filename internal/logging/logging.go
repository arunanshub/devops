// Package logging configures the process-wide slog default logger.
package logging

import (
	"log/slog"
	"os"

	"github.com/charmbracelet/log"
)

// Setup installs a charmbracelet-backed logger as the slog default at the
// given level, so the rest of the program can use the slog package functions
// (or slog.Default().WithGroup(...) for scoped loggers) without threading a
// logger through every constructor. Unknown level strings fall back to info.
func Setup(level string) {
	lvl, err := log.ParseLevel(level)
	if err != nil {
		lvl = log.InfoLevel
	}

	logger := log.NewWithOptions(os.Stderr, log.Options{
		ReportCaller:    lvl <= log.DebugLevel,
		ReportTimestamp: true,
		Level:           lvl,
		Prefix:          "🧰 opsctl",
	})

	slog.SetDefault(slog.New(logger))
}
