package main

type getVPACmd struct{}

func (m *getVPACmd) Run(ctx *context) error {
	log := ctx.Logger

	log = log.WithGroup("vpa")
	log.Debug("this is working!")

	return nil
}
