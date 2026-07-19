package main

type verifyMtuCmd struct {
	Name string `help:"what is the name of the tooling"`
}

func (m *verifyMtuCmd) Run(ctx *context) error {
	log := ctx.Logger.WithGroup("mtu")

	log.Debug("foo")

	return nil
}
