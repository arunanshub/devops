package main

import (
	"github.com/charmbracelet/log"
)

type verifyMtuCmd struct {
	Name string `help:"what is the name of the tooling"`
}

type context struct {
	Logger *log.Logger
}

func (m *verifyMtuCmd) Run(ctx *context) error {
	log := ctx.Logger
	log.Debug("this works!")
	return nil
}
