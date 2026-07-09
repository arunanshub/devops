package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"time"

	"github.com/goccy/go-yaml"
)

type vpa struct {
	Items []Item `yaml:"items"`
}

type Item struct {
	Metadata struct {
		Name      string `yaml:"name"`
		Namespace string `yaml:"namespace"`
	}
	Spec struct {
		UpdatePolicy struct {
			UpdateMode string `yaml:"updateMode"`
		} `yaml:"updatePolicy"`
	}
}

func main() {
	if err := run(); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
}

func run() error {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second*5)
	defer cancel()

	c := exec.CommandContext(ctx, "kubectl", "get", "vpa", "-A", "-o", "yaml")
	out, err := c.Output()
	if err != nil {
		return err
	}

	var parsed vpa
	err = yaml.Unmarshal(out, &parsed)
	if err != nil {
		return err
	}

	var initials []Item
	for _, item := range parsed.Items {
		if item.Spec.UpdatePolicy.UpdateMode == "Initial" {
			initials = append(initials, item)
		}
	}

	for _, item := range initials {
		fmt.Printf("%+v\n", item.Metadata)
	}
	return nil
}
