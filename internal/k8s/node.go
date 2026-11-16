package k8s

import (
	"context"
	"fmt"
)

// NodeConfigz fetches the node's live kubelet configuration document via the
// API server's node proxy — a direct kubelet probe that, unlike the Ready
// condition, cannot be stale.
func (c *Client) NodeConfigz(ctx context.Context, node string) ([]byte, error) {
	data, err := c.clientset.CoreV1().RESTClient().
		Get().
		AbsPath("/api/v1/nodes/" + node + "/proxy/configz").
		DoRaw(ctx)
	if err != nil {
		return nil, fmt.Errorf("fetch configz for node %s: %w", node, err)
	}
	return data, nil
}
