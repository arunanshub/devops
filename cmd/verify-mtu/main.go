package main

import (
	"context"
	"fmt"
	"log"
	"log/slog"
	"os"

	v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
)

func main() {
	flags, err := getFlags()
	if err != nil || flags == nil {
		log.Fatalf("failed to parse flags: %v", err)
	}

	if err := run(flags); err != nil {
		slog.Error("Failed to verify mtu", slog.String("error", err.Error()))
		os.Exit(1)
	}
}

func run(flags *cli) error {
	ctx, cancel := context.WithTimeout(context.Background(), flags.Timeout)
	defer cancel()

	config, err := clientcmd.BuildConfigFromFlags("", flags.Kubeconfig)
	if err != nil {
		return fmt.Errorf("failed to get kubeconfig: %w", err)
	}

	// create the clientset
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return fmt.Errorf("failed to read config: %w", err)
	}

	if v, err := hasRequiredNodes(ctx, clientset); err != nil {
		return fmt.Errorf("failed to get required no. of nodes: %w", err)
	} else if !v {
		return fmt.Errorf("not sufficient amounts of nodes available")
	}

	runner := NewPodRunner(
		clientset,
		PodSpec{Name: new("mtu-verify-a"), Namespace: "default", Image: "busybox:1.36"},
	)
	if err := runner.Run(ctx); err != nil {
		return fmt.Errorf("failed to run pod: %w", err)
	}

	return nil
}

func hasRequiredNodes(ctx context.Context, client *kubernetes.Clientset) (bool, error) {
	nodes, err := client.CoreV1().Nodes().List(ctx, v1.ListOptions{Limit: 3})
	if err != nil {
		return false, fmt.Errorf("failed to get no of nodes: %w", err)
	}

	if len(nodes.Items) >= 3 {
		return true, nil
	}

	return false, nil
}
