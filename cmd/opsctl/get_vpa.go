package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"text/tabwriter"
	"time"

	"github.com/arunanshub/devops/internal/k8s"
	"github.com/arunanshub/devops/internal/logging"
	"github.com/arunanshub/devops/internal/vpa"
	"k8s.io/client-go/dynamic"
)

// getVPACmd lists VPAs whose updateMode differs from the expected one —
// useful for spotting VPAs that were never switched to in-place resizing.
type getVPACmd struct {
	Kubeconfig string        `env:"KUBECONFIG" required:"" type:"existingfile" help:"Path to kubeconfig."`
	ExpectMode string        `default:"InPlaceOrRecreate" help:"List VPAs whose updateMode differs from this."`
	Timeout    time.Duration `default:"30s" help:"Overall timeout."`
}

func (c *getVPACmd) Run(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, c.Timeout)
	defer cancel()

	ctx, end := logging.Span(ctx, "get-vpa", slog.String("expect_mode", c.ExpectMode))
	defer end()

	restConfig, err := k8s.NewRESTConfig(c.Kubeconfig)
	if err != nil {
		return err
	}
	client, err := dynamic.NewForConfig(restConfig)
	if err != nil {
		return fmt.Errorf("create dynamic client: %w", err)
	}

	vpas, err := vpa.List(ctx, client)
	if err != nil {
		return err
	}

	strays := vpa.FilterNotMode(vpas, c.ExpectMode)
	if len(strays) == 0 {
		logging.FromContext(ctx).InfoContext(ctx, "all VPAs use the expected update mode",
			slog.Int("total", len(vpas)))
		return nil
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "NAMESPACE\tNAME\tUPDATE MODE")
	for _, v := range strays {
		fmt.Fprintf(w, "%s\t%s\t%s\n", v.Namespace, v.Name, v.UpdateMode)
	}
	return w.Flush()
}
