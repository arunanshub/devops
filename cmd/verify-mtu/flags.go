package main

import (
	"fmt"
	"time"

	"github.com/alecthomas/kong"
)

type cli struct {
	Kubeconfig         string        `arg:"" help:"Path to kubeconfig" type:"existingfile"`
	ExpectedWgMTU      int           `default:"1355"`
	ExpectedPodMTU     int           `default:"1450"`
	CeilingPayloadSize int           `default:"1276"`
	PassPayload        int           `default:"1200"`
	Timeout            time.Duration `default:"5s"`
}

func getFlags() (*cli, error) {
	var cli cli
	parsed := kong.Parse(&cli)
	if parsed.Error != nil {
		return nil, fmt.Errorf("failed to parse arguments: %w", parsed.Error)
	}

	return &cli, nil
}
