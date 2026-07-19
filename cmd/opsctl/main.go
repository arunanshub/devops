package main

import (
	"log/slog"

	"github.com/alecthomas/kong"
	"github.com/arunanshub/devops/internal/logging"
)

type context struct {
	Logger *slog.Logger
}

type cli struct {
	VerifyMTU verifyMtuCmd `cmd:"" help:"verifies your mtu"`
	GetVPA    getVPACmd    `cmd:"" help:"Get all the VPA in the cluster"`
}

func main() {
	log := logging.NewLogger()

	var cli cli
	ctx := kong.Parse(&cli,
		kong.Description("The operations toolkit :)"),
		kong.UsageOnError(),
		kong.ConfigureHelp(kong.HelpOptions{
			Compact: true,
		}),
	)

	err := ctx.Run(&context{Logger: log})
	if err != nil {
		log.Error("failed to execute command", "error", err)
	}

	ctx.FatalIfErrorf(err)
}
