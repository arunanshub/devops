package main

import (
	"github.com/alecthomas/kong"
	"github.com/arunanshub/devops/internal/logging"
)

var cli struct {
	VerifyMTU verifyMtuCmd `cmd:"" help:"verifies your mtu"`
}

func main() {
	log := logging.NewLogger()

	ctx := kong.Parse(&cli,
		kong.Description("The operations toolkit :)"),
		kong.ShortUsageOnError(),
		kong.ConfigureHelp(kong.HelpOptions{
			Compact: true,
		}),
	)

	err := ctx.Run(&context{Logger: log})
	if err != nil {
		log.Fatalf("failed to execute command: %v", err)
	}
}
