package main

import (
	"github.com/alecthomas/kong"
	"github.com/arunanshub/devops/internal/logging"
)

var cli struct {
	VerifyMTU verifyMtuCmd `cmd:"" help:"verifies your mtu"`
	GetVPA    getVPACmd    `cmd:"" help:"Get all the VPA in the cluster"`
}

func main() {
	log := logging.NewLogger()

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
