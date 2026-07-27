package adoption

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestMergeMaps(t *testing.T) {
	tests := []struct {
		name string
		dst  map[string]any
		src  map[string]any
		want map[string]any
	}{
		{
			name: "nested maps merge recursively",
			dst:  map[string]any{"a": map[string]any{"x": 1, "y": 2}},
			src:  map[string]any{"a": map[string]any{"y": 3, "z": 4}},
			want: map[string]any{"a": map[string]any{"x": 1, "y": 3, "z": 4}},
		},
		{
			name: "lists are replaced, not appended",
			dst:  map[string]any{"list": []any{1, 2}},
			src:  map[string]any{"list": []any{3}},
			want: map[string]any{"list": []any{3}},
		},
		{
			name: "scalar replaces map",
			dst:  map[string]any{"a": map[string]any{"x": 1}},
			src:  map[string]any{"a": "flat"},
			want: map[string]any{"a": "flat"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			assert.Equal(t, tt.want, mergeMaps(tt.dst, tt.src))
		})
	}
}

func TestDeletePath(t *testing.T) {
	values := map[string]any{
		"configs": map[string]any{
			"secret": map[string]any{
				"adminPassword": "hash",
				"other":         "keep",
			},
		},
	}

	deletePath(values, "configs.secret.adminPassword")
	deletePath(values, "does.not.exist")

	configs, ok := values["configs"].(map[string]any)
	require.True(t, ok)
	secret, ok := configs["secret"].(map[string]any)
	require.True(t, ok)
	assert.NotContains(t, secret, "adminPassword")
	assert.Equal(t, "keep", secret["other"])
}

// writeTree materializes a fixture repo layout for end-to-end Verify tests.
func writeTree(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for rel, content := range files {
		full := filepath.Join(root, rel)
		require.NoError(t, os.MkdirAll(filepath.Dir(full), 0o755))
		require.NoError(t, os.WriteFile(full, []byte(content), 0o644))
	}
	return root
}

const fixtureHelmfile = `releases:
  - name: demo
    chart: repo/demo
    version: "1.2.3"
    values:
      - values/demo.yaml.gotmpl
`

const fixtureApp = `apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  sources:
    - repoURL: https://example.com/charts
      chart: demo
      targetRevision: 1.2.3
      helm:
        releaseName: demo
        valueFiles:
          - $values/base/demo/values.yaml
    - repoURL: git@example.com:repo.git
      targetRevision: master
      ref: values
`

func TestVerifyHappyPath(t *testing.T) {
	t.Setenv("DEMO_ENDPOINT", "10.0.0.100")
	root := writeTree(t, map[string]string{
		"bootstrap/helmfile.yaml":           fixtureHelmfile,
		"bootstrap/values/demo.yaml.gotmpl": "host: {{ requiredEnv \"DEMO_ENDPOINT\" }}\nreplicas: 2\n",
		"base/demo/application.yaml":        fixtureApp,
		"base/demo/values.yaml":             "# comments differ, values match\nhost: 10.0.0.100\nreplicas: 2\n",
	})

	findings, err := Verify(t.Context(), root, "bootstrap/helmfile.yaml",
		[]Pair{{Release: "demo", AppPath: "base/demo/application.yaml"}})
	require.NoError(t, err)
	assert.Empty(t, findings)
}

func TestVerifyDetectsDrift(t *testing.T) {
	t.Setenv("DEMO_ENDPOINT", "10.0.0.100")
	root := writeTree(t, map[string]string{
		"bootstrap/helmfile.yaml":           fixtureHelmfile,
		"bootstrap/values/demo.yaml.gotmpl": "host: {{ requiredEnv \"DEMO_ENDPOINT\" }}\nreplicas: 1\n",
		"base/demo/application.yaml":        fixtureApp,
		"base/demo/values.yaml":             "host: 10.0.0.200\nreplicas: 2\nextra: true\n",
	})

	findings, err := Verify(t.Context(), root, "bootstrap/helmfile.yaml",
		[]Pair{{Release: "demo", AppPath: "base/demo/application.yaml"}})
	require.NoError(t, err)
	// one values-drift finding (the cmp diff) + the fix-hint line.
	require.Len(t, findings, 2, "findings: %v", findings)
	assert.Contains(t, findings[0].Problem, "values drift")
	assert.Contains(t, findings[0].Problem, "replicas")
	assert.Contains(t, findings[0].Problem, "extra")
}

func TestVerifyDetectsVersionAndReleaseNameMismatch(t *testing.T) {
	app := `apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  sources:
    - repoURL: https://example.com/charts
      chart: demo
      targetRevision: 2.0.0
      helm:
        releaseName: demo-renamed
        valueFiles:
          - $values/base/demo/values.yaml
`
	root := writeTree(t, map[string]string{
		"bootstrap/helmfile.yaml":           fixtureHelmfile,
		"bootstrap/values/demo.yaml.gotmpl": "a: 1\n",
		"base/demo/application.yaml":        app,
		"base/demo/values.yaml":             "a: 1\n",
	})

	findings, err := Verify(t.Context(), root, "bootstrap/helmfile.yaml",
		[]Pair{{Release: "demo", AppPath: "base/demo/application.yaml"}})
	require.NoError(t, err)
	// version drift + releaseName mismatch + fix-hint.
	require.Len(t, findings, 3, "findings: %v", findings)
	assert.Contains(t, findings[0].Problem, "chart version drift")
	assert.Contains(t, findings[1].Problem, "releaseName mismatch")
}

func TestVerifyIgnorePaths(t *testing.T) {
	root := writeTree(t, map[string]string{
		"bootstrap/helmfile.yaml":           fixtureHelmfile,
		"bootstrap/values/demo.yaml.gotmpl": "a: 1\nsecret:\n  adminPassword: bootstrap-only\n",
		"base/demo/application.yaml":        fixtureApp,
		"base/demo/values.yaml":             "a: 1\n",
	})

	findings, err := Verify(t.Context(), root, "bootstrap/helmfile.yaml",
		[]Pair{{
			Release: "demo",
			AppPath: "base/demo/application.yaml",
			// Deleting the leaf leaves secret: {} behind; EquateEmpty must
			// treat that the same as the key being absent on the other side.
			IgnorePaths: []string{"secret.adminPassword"},
		}})
	require.NoError(t, err)
	assert.Empty(t, findings)
}

func TestVerifyUnknownReleaseErrors(t *testing.T) {
	root := writeTree(t, map[string]string{
		"bootstrap/helmfile.yaml": fixtureHelmfile,
	})

	_, err := Verify(t.Context(), root, "bootstrap/helmfile.yaml",
		[]Pair{{Release: "missing", AppPath: "nowhere.yaml"}})
	require.Error(t, err)
}
