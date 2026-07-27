// Package k8s wraps client-go with the small set of cluster operations
// opsctl commands need: running short-lived pods, exec-ing into them,
// reading config, and port-forwarding.
package k8s

import (
	"context"
	"fmt"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

// Client bundles the typed clientset with the rest.Config needed for
// subresource operations (exec, port-forward).
type Client struct {
	clientset  kubernetes.Interface
	restConfig *rest.Config
}

// NewRESTConfig builds a rest.Config from a kubeconfig file path.
func NewRESTConfig(kubeconfig string) (*rest.Config, error) {
	restConfig, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		return nil, fmt.Errorf("build rest config from kubeconfig %q: %w", kubeconfig, err)
	}
	return restConfig, nil
}

// NewClient builds a Client from a kubeconfig file path.
func NewClient(kubeconfig string) (*Client, error) {
	restConfig, err := NewRESTConfig(kubeconfig)
	if err != nil {
		return nil, err
	}

	clientset, err := kubernetes.NewForConfig(restConfig)
	if err != nil {
		return nil, fmt.Errorf("create clientset: %w", err)
	}

	return &Client{clientset: clientset, restConfig: restConfig}, nil
}

// NodeNames returns the names of all nodes in the cluster, in API order.
func (c *Client) NodeNames(ctx context.Context) ([]string, error) {
	nodes, err := c.clientset.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("list nodes: %w", err)
	}

	names := make([]string, 0, len(nodes.Items))
	for i := range nodes.Items {
		names = append(names, nodes.Items[i].Name)
	}
	return names, nil
}

// PodInfo identifies a pod and the node it is scheduled on.
type PodInfo struct {
	Name     string
	NodeName string
}

// PodsByLabel returns name and node of every pod in namespace matching the
// label selector.
func (c *Client) PodsByLabel(ctx context.Context, namespace, selector string) ([]PodInfo, error) {
	pods, err := c.clientset.CoreV1().
		Pods(namespace).
		List(ctx, metav1.ListOptions{LabelSelector: selector})
	if err != nil {
		return nil, fmt.Errorf("list pods in %q with selector %q: %w", namespace, selector, err)
	}

	infos := make([]PodInfo, 0, len(pods.Items))
	for i := range pods.Items {
		infos = append(
			infos,
			PodInfo{Name: pods.Items[i].Name, NodeName: pods.Items[i].Spec.NodeName},
		)
	}
	return infos, nil
}

// ConfigMapData returns the data map of a ConfigMap.
func (c *Client) ConfigMapData(
	ctx context.Context,
	namespace, name string,
) (map[string]string, error) {
	cm, err := c.clientset.CoreV1().ConfigMaps(namespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("get configmap %s/%s: %w", namespace, name, err)
	}
	return cm.Data, nil
}
