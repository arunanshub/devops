// opsctl is the operations toolkit for this repo's cluster: health checks and
// operator utilities that used to live as shell recipes and standalone tools.
package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/alecthomas/kong"

	"github.com/arunanshub/devops/internal/logging"
)

type cli struct {
	LogLevel string `help:"Log level." enum:"debug,info,warn,error" default:"info"`

	Cluster          clusterCmd             `cmd:"" help:"Whole-cluster operations: bootstrap, verify."`
	VerifyMTU        verifyMTUCmd           `cmd:"" name:"verify-mtu"        help:"Verify the VXLAN+WireGuard MTU stack is correctly configured."`
	VerifyAdoption   verifyAdoptionCmd      `cmd:"" name:"verify-adoption"   help:"Verify helmfile-installed releases match their adopting ArgoCD Applications."`
	VerifyNodeConfig verifyNodeConfigCmd    `cmd:"" name:"verify-node-config" help:"Validate nodes/ config against the pinned k3s and kubelet flag schemas."`
	VerifyKubelet    verifyKubeletConfigCmd `cmd:"" name:"verify-kubelet-config" help:"Assert a node's live kubelet config matches the declared kubelet-args."`
	GetVPA           getVPACmd              `cmd:"" name:"get-vpa"           help:"List VPAs whose updateMode differs from the expected one."`
}

func main() {
	if err := run(); err != nil {
		os.Exit(1)
	}
}

func run() error {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	var cli cli
	kctx := kong.Parse(&cli,
		kong.Description("The operations toolkit :)"),
		kong.UsageOnError(),
		kong.ConfigureHelp(kong.HelpOptions{
			Compact: true,
		}),
		kong.BindTo(ctx, (*context.Context)(nil)),
	)

	logging.Setup(cli.LogLevel)
	if err := kctx.Run(); err != nil {
		slog.Error("command failed", slog.Any("error", err))
		return err
	}
	return nil
}
