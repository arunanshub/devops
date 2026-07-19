package logging

import (
	"log/slog"
	"os"

	"github.com/charmbracelet/log"
)

func NewLogger() *slog.Logger {
	logger := log.NewWithOptions(os.Stderr, log.Options{
		ReportCaller:    true,
		ReportTimestamp: true,
		Level:           log.DebugLevel,
		Prefix:          "🧰 opsctl",
	})

	slogger := slog.New(logger)

	return slogger
}
