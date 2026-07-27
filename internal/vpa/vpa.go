// Package vpa lists VerticalPodAutoscaler objects via the dynamic client, so
// opsctl does not have to shell out to kubectl.
package vpa

import (
	"context"
	"fmt"
	"log/slog"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"

	"github.com/arunanshub/devops/internal/logging"
)

// GVR identifies the VerticalPodAutoscaler custom resource.
var GVR = schema.GroupVersionResource{
	Group:    "autoscaling.k8s.io",
	Version:  "v1",
	Resource: "verticalpodautoscalers",
}

// VPA is the subset of a VerticalPodAutoscaler opsctl cares about.
type VPA struct {
	Namespace  string
	Name       string
	UpdateMode string
}

// List returns every VPA in the cluster.
func List(ctx context.Context, client dynamic.Interface) ([]VPA, error) {
	list, err := client.Resource(GVR).Namespace(metav1.NamespaceAll).List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("list verticalpodautoscalers: %w", err)
	}
	logging.FromContext(ctx).DebugContext(ctx, "listed VPAs", slog.Int("count", len(list.Items)))

	vpas := make([]VPA, 0, len(list.Items))
	for i := range list.Items {
		item := &list.Items[i]
		mode, _, err := unstructured.NestedString(item.Object, "spec", "updatePolicy", "updateMode")
		if err != nil {
			return nil, fmt.Errorf(
				"read updateMode of %s/%s: %w",
				item.GetNamespace(),
				item.GetName(),
				err,
			)
		}

		vpas = append(vpas, VPA{
			Namespace:  item.GetNamespace(),
			Name:       item.GetName(),
			UpdateMode: mode,
		})
	}
	return vpas, nil
}

// FilterNotMode returns the VPAs whose updateMode differs from mode.
func FilterNotMode(vpas []VPA, mode string) []VPA {
	var filtered []VPA
	for _, v := range vpas {
		if v.UpdateMode != mode {
			filtered = append(filtered, v)
		}
	}
	return filtered
}
