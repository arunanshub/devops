package vpa

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	dynamicfake "k8s.io/client-go/dynamic/fake"
)

func vpaObject(namespace, name, updateMode string) *unstructured.Unstructured {
	obj := &unstructured.Unstructured{
		Object: map[string]any{
			"apiVersion": "autoscaling.k8s.io/v1",
			"kind":       "VerticalPodAutoscaler",
			"metadata": map[string]any{
				"name":      name,
				"namespace": namespace,
			},
			"spec": map[string]any{
				"updatePolicy": map[string]any{
					"updateMode": updateMode,
				},
			},
		},
	}
	return obj
}

func TestListReturnsAllVPAsWithUpdateMode(t *testing.T) {
	scheme := runtime.NewScheme()
	client := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(
		scheme,
		map[schema.GroupVersionResource]string{GVR: "VerticalPodAutoscalerList"},
		vpaObject("monitoring", "vmsingle", "InPlaceOrRecreate"),
		vpaObject("traefik", "traefik", "Initial"),
	)

	vpas, err := List(t.Context(), client)
	require.NoError(t, err)
	require.Len(t, vpas, 2)

	byName := map[string]VPA{}
	for _, v := range vpas {
		byName[v.Name] = v
	}
	assert.Equal(t, "InPlaceOrRecreate", byName["vmsingle"].UpdateMode)
	assert.Equal(t, "monitoring", byName["vmsingle"].Namespace)
	assert.Equal(t, "Initial", byName["traefik"].UpdateMode)
}

func TestFilterNotMode(t *testing.T) {
	vpas := []VPA{
		{Namespace: "monitoring", Name: "vmsingle", UpdateMode: "InPlaceOrRecreate"},
		{Namespace: "traefik", Name: "traefik", UpdateMode: "Initial"},
		{Namespace: "velero", Name: "velero", UpdateMode: "Off"},
	}

	filtered := FilterNotMode(vpas, "InPlaceOrRecreate")
	require.Len(t, filtered, 2)
	assert.Equal(t, "traefik", filtered[0].Name)
	assert.Equal(t, "velero", filtered[1].Name)
}
