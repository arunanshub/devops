package adoption

import (
	"fmt"
	"os"
	"path/filepath"

	"sigs.k8s.io/yaml"
)

// helmfileSpec is the subset of a helmfile we consume.
type helmfileSpec struct {
	Releases []helmfileRelease `json:"releases"`

	// path is the repo-relative helmfile location, kept for error messages
	// and for resolving the release-relative values paths.
	path string `json:"-"`
	dir  string `json:"-"`
}

// helmfileRelease is one release entry. Values entries that are not plain
// file paths (inline maps) are not supported and rejected during parsing.
type helmfileRelease struct {
	Name    string   `json:"name"`
	Chart   string   `json:"chart"`
	Version string   `json:"version"`
	Values  []string `json:"values"`

	dir string `json:"-"`
}

func loadHelmfile(repoRoot, path string) (*helmfileSpec, error) {
	full := filepath.Join(repoRoot, path)
	data, err := os.ReadFile(full)
	if err != nil {
		return nil, fmt.Errorf("read helmfile: %w", err)
	}

	// Lenient parse: the helmfile has fields we don't model (repositories,
	// needs, hooks, ...). An inline values map instead of a file path would
	// fail the []string field here, which is intentional — unsupported.
	var spec helmfileSpec
	if err := yaml.Unmarshal(data, &spec); err != nil {
		return nil, fmt.Errorf("parse helmfile %s: %w", path, err)
	}

	spec.path = path
	spec.dir = filepath.Dir(full)
	for i := range spec.Releases {
		spec.Releases[i].dir = spec.dir
	}
	return &spec, nil
}

func (h *helmfileSpec) release(name string) (helmfileRelease, bool) {
	for _, r := range h.Releases {
		if r.Name == name {
			return r, true
		}
	}
	return helmfileRelease{}, false
}

// renderValues renders and helm-merges every values file of the release, in
// order. Paths are relative to the helmfile directory. Files ending in
// .gotmpl are rendered as helmfile does, with env/requiredEnv functions.
func (r *helmfileRelease) renderValues() (map[string]any, error) {
	merged := map[string]any{}
	for _, rel := range r.Values {
		values, err := loadValuesFile(filepath.Join(r.dir, rel))
		if err != nil {
			return nil, err
		}
		merged = mergeMaps(merged, values)
	}
	return merged, nil
}
