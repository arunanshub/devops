package main

import (
	"log/slog"
)

type verifyMtuCmd struct {
	Name string `help:"what is the name of the tooling"`
}

type context struct {
	Logger *slog.Logger
}

func (m *verifyMtuCmd) Run(ctx *context) error {
	log := ctx.Logger.WithGroup("mtu")

	log.Debug("foo")

	return nil
}
