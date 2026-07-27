package k8s

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/arunanshub/devops/internal/logging"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/client-go/dynamic"
)

// NodeStatus is one node's readiness.
type NodeStatus struct {
	Name  string
	Ready bool
}

// NodeStatuses returns every node with its Ready condition.
func (c *Client) NodeStatuses(ctx context.Context) ([]NodeStatus, error) {
	nodes, err := c.clientset.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("list nodes: %w", err)
	}

	statuses := make([]NodeStatus, 0, len(nodes.Items))
	for i := range nodes.Items {
		statuses = append(statuses, NodeStatus{
			Name:  nodes.Items[i].Name,
			Ready: isNodeReady(&nodes.Items[i]),
		})
	}
	return statuses, nil
}

// WaitNodeReady blocks until the named node exists and reports Ready — used
// after provisioning, where the node may not exist yet while cloud-init
// installs k3s.
func (c *Client) WaitNodeReady(ctx context.Context, name string, timeout time.Duration) error {
	log := logging.FromContext(ctx)
	return wait.PollUntilContextTimeout(ctx, pollInterval, timeout, true,
		func(ctx context.Context) (bool, error) {
			node, err := c.clientset.CoreV1().Nodes().Get(ctx, name, metav1.GetOptions{})
			if apierrors.IsNotFound(err) {
				return false, nil
			}
			if err != nil {
				// The API server may blip while a control-plane node
				// joins; keep polling instead of aborting.
				log.DebugContext(ctx, "node poll failed, retrying", slog.Any("error", err))
				return false, nil
			}
			return isNodeReady(node), nil
		})
}

func isNodeReady(node *corev1.Node) bool {
	for _, cond := range node.Status.Conditions {
		if cond.Type == corev1.NodeReady && cond.Status == corev1.ConditionTrue {
			return true
		}
	}
	return false
}

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

var applicationGVR = schema.GroupVersionResource{
	Group:    "argoproj.io",
	Version:  "v1alpha1",
	Resource: "applications",
}

// HasApplication reports whether an ArgoCD Application exists. A missing
// Application CRD counts as "no" — that's the state of a half-bootstrapped
// cluster.
func (c *Client) HasApplication(ctx context.Context, namespace, name string) (bool, error) {
	dyn, err := dynamic.NewForConfig(c.restConfig)
	if err != nil {
		return false, fmt.Errorf("create dynamic client: %w", err)
	}

	_, err = dyn.Resource(applicationGVR).Namespace(namespace).Get(ctx, name, metav1.GetOptions{})
	switch {
	case err == nil:
		return true, nil
	case apierrors.IsNotFound(err):
		return false, nil
	default:
		return false, fmt.Errorf("get Application %s/%s: %w", namespace, name, err)
	}
}
