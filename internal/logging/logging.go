package logging

import (
	"os"

	"github.com/charmbracelet/log"
)

func NewLogger() *log.Logger {
	logger := log.NewWithOptions(os.Stderr, log.Options{
		ReportCaller:    true,
		ReportTimestamp: true,
		Level:           log.DebugLevel,
		Prefix:          "🧰 opsctl",
	})
	return logger
}
