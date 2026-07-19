package main

import (
	"github.com/alecthomas/kong"
	"github.com/arunanshub/devops/internal/logging"
)

type cli struct{}

func main() {
	var cli cli
	kong.Parse(&cli)

	log := logging.NewLogger()
	log.Debug("hello world!")
	log.Error("NO!!!!")
}
