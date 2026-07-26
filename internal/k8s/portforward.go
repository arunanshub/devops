package k8s

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"

	"github.com/arunanshub/devops/internal/logging"
	"k8s.io/client-go/tools/portforward"
	"k8s.io/client-go/transport/spdy"
)

// PortForward forwards a random local port to remotePort on the pod. It
// returns the chosen local port and a stop function that must be called to
// tear the forwarder down. The forwarder also stops when ctx is cancelled.
func (c *Client) PortForward(
	ctx context.Context,
	namespace, pod string,
	remotePort uint16,
) (uint16, func(), error) {
	req := c.clientset.CoreV1().RESTClient().
		Post().
		Resource("pods").
		Namespace(namespace).
		Name(pod).
		SubResource("portforward")

	transport, upgrader, err := spdy.RoundTripperFor(c.restConfig)
	if err != nil {
		return 0, nil, fmt.Errorf("create spdy round tripper: %w", err)
	}
	dialer := spdy.NewDialer(
		upgrader,
		&http.Client{Transport: transport},
		http.MethodPost,
		req.URL(),
	)

	stopCh := make(chan struct{})
	readyCh := make(chan struct{})
	forwarder, err := portforward.New(
		dialer,
		[]string{fmt.Sprintf("0:%d", remotePort)},
		stopCh, readyCh,
		io.Discard, io.Discard,
	)
	if err != nil {
		return 0, nil, fmt.Errorf("create port forwarder for pod %s/%s: %w", namespace, pod, err)
	}

	errCh := make(chan error, 1)
	go func() { errCh <- forwarder.ForwardPorts() }()

	stop := func() { close(stopCh) }

	select {
	case <-readyCh:
	case err := <-errCh:
		return 0, nil, fmt.Errorf("port forward to pod %s/%s: %w", namespace, pod, err)
	case <-ctx.Done():
		stop()
		return 0, nil, fmt.Errorf("port forward to pod %s/%s: %w", namespace, pod, ctx.Err())
	}

	ports, err := forwarder.GetPorts()
	if err != nil || len(ports) == 0 {
		stop()
		return 0, nil, fmt.Errorf("get forwarded ports for pod %s/%s: %w", namespace, pod, err)
	}

	logging.FromContext(ctx).DebugContext(ctx, "port forward established",
		slog.String("pod", pod), slog.Uint64("local_port", uint64(ports[0].Local)))
	return ports[0].Local, stop, nil
}
