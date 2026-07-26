package main

import (
	"context"
	"errors"
	"os"
	"time"

	"github.com/arunanshub/devops/internal/k8s"
	"github.com/arunanshub/devops/internal/logging"
	"github.com/arunanshub/devops/internal/mtu"
)

// verifyMTUCmd verifies the VXLAN+WireGuard MTU stack. Run it after bootstrap
// or any Cilium config change. The expected values are documented on the
// flags and in docs/cilium-mtu-overlay-networking.md.
type verifyMTUCmd struct {
	Kubeconfig     string        `env:"KUBECONFIG" required:"" type:"existingfile" help:"Path to kubeconfig."`
	Namespace      string        `default:"default" help:"Namespace for the throwaway test pods."`
	Image          string        `default:"busybox:1.36" help:"Image for the test pods; must ship ping and ip."`
	ExpectedWgMTU  int           `default:"1355" help:"cilium_wg0 MTU: enp7s0 1450 - WireGuard IPv6 overhead 95 (Cilium >= 1.20.0-pre.3; 80/1370 on <= pre.2)."`
	ExpectedPodMTU int           `default:"1450" help:"Pod eth0 MTU (Cilium uses the native device MTU)."`
	CeilingPayload int           `default:"1276" help:"ICMP payload at the VXLAN+WG path ceiling: overlay clamp 1305 - 28 header - 1 slack."`
	PassPayload    int           `default:"1200" help:"ICMP payload comfortably below the ceiling."`
	MinQuicMTU     int           `default:"1300" help:"Minimum acceptable cloudflared quic_client_mtu (expected ~1344 at pod MTU 1450)."`
	ReadyTimeout   time.Duration `default:"90s" help:"How long the test pods may take to become Ready."`
	Timeout        time.Duration `default:"5m" help:"Overall timeout."`
}

func (c *verifyMTUCmd) Run(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, c.Timeout)
	defer cancel()

	ctx, end := logging.Span(ctx, "verify-mtu")
	defer end()

	client, err := k8s.NewClient(c.Kubeconfig)
	if err != nil {
		return err
	}

	verifier := mtu.NewVerifier(client, &mtu.Config{
		Namespace:      c.Namespace,
		Image:          c.Image,
		ExpectedWgMTU:  c.ExpectedWgMTU,
		ExpectedPodMTU: c.ExpectedPodMTU,
		CeilingPayload: c.CeilingPayload,
		PassPayload:    c.PassPayload,
		MinQuicMTU:     c.MinQuicMTU,
		ReadyTimeout:   c.ReadyTimeout,
	})

	report, err := verifier.Run(ctx)
	if err != nil {
		return err
	}

	report.Render(os.Stdout)
	if !report.Passed() {
		return errors.New("MTU verification failed")
	}
	return nil
}
