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
	Kubeconfig     string        `env:"KUBECONFIG" help:"Path to kubeconfig."                                                                                     required:"" type:"existingfile"`
	Namespace      string        `                 help:"Namespace for the throwaway test pods."                                                                                                  default:"default"`
	Image          string        `                 help:"Image for the test pods; must ship ping and ip."                                                                                         default:"busybox:1.36"`
	ExpectedWgMTU  int           `                 help:"cilium_wg0 MTU: enp7s0 1450 - WireGuard IPv6 overhead 95 (Cilium >= 1.20.0-pre.3; 80/1370 on <= pre.2)."                                 default:"1355"`
	ExpectedPodMTU int           `                 help:"Pod eth0 MTU (Cilium uses the native device MTU)."                                                                                       default:"1450"`
	CeilingPayload int           `                 help:"ICMP payload at the VXLAN+WG path ceiling: overlay clamp 1305 - 28 header - 1 slack."                                                    default:"1276"`
	PassPayload    int           `                 help:"ICMP payload comfortably below the ceiling."                                                                                             default:"1200"`
	MinQuicMTU     int           `                 help:"Minimum acceptable cloudflared quic_client_mtu (expected ~1344 at pod MTU 1450)."                                                        default:"1300"`
	ReadyTimeout   time.Duration `                 help:"How long the test pods may take to become Ready."                                                                                        default:"90s"`
	Timeout        time.Duration `                 help:"Overall timeout."                                                                                                                        default:"5m"`
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
