package k8s

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/remotecommand"

	"github.com/arunanshub/devops/internal/logging"
)

// Exec runs command inside a pod's container and returns captured stdout and
// stderr. An empty container selects the pod's default container. The command
// exiting non-zero is returned as an error alongside whatever output was
// captured, so callers may still inspect stdout.
func (c *Client) Exec(
	ctx context.Context,
	namespace, pod, container string,
	command []string,
) (string, string, error) {
	logging.FromContext(ctx).DebugContext(ctx, "exec in pod",
		slog.String("pod", pod), slog.Any("command", command))

	req := c.clientset.CoreV1().RESTClient().
		Post().
		Resource("pods").
		Namespace(namespace).
		Name(pod).
		SubResource("exec").
		VersionedParams(&corev1.PodExecOptions{
			Container: container,
			Command:   command,
			Stdout:    true,
			Stderr:    true,
		}, scheme.ParameterCodec)

	executor, err := remotecommand.NewSPDYExecutor(c.restConfig, "POST", req.URL())
	if err != nil {
		return "", "", fmt.Errorf("create exec executor for pod %s/%s: %w", namespace, pod, err)
	}

	var stdout, stderr bytes.Buffer
	err = executor.StreamWithContext(ctx, remotecommand.StreamOptions{
		Stdout: &stdout,
		Stderr: &stderr,
	})
	if err != nil {
		return stdout.String(), stderr.String(),
			fmt.Errorf("exec %v in pod %s/%s: %w", command, namespace, pod, err)
	}

	return stdout.String(), stderr.String(), nil
}
