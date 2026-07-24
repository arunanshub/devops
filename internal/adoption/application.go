package adoption

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"sigs.k8s.io/yaml"
)

// valuesRefPrefix marks Application valueFiles entries that resolve against
// this repo (the ArgoCD multi-source $values pattern).
const valuesRefPrefix = "$values/"

// appSpec is the subset of an ArgoCD Application we consume: the helm chart
// source and its values references.
type appSpec struct {
	Chart          string
	TargetRevision string
	ReleaseName    string
	ValueFiles     []string
}

type applicationManifest struct {
	Spec struct {
		Sources []struct {
			RepoURL        string `json:"repoURL"`
			Chart          string `json:"chart"`
			TargetRevision string `json:"targetRevision"`
			Helm           *struct {
				ReleaseName string   `json:"releaseName"`
				ValueFiles  []string `json:"valueFiles"`
			} `json:"helm"`
		} `json:"sources"`
	} `json:"spec"`
}

func loadApplication(repoRoot, path string) (*appSpec, error) {
	data, err := os.ReadFile(filepath.Join(repoRoot, path))
	if err != nil {
		return nil, fmt.Errorf("read Application: %w", err)
	}

	var manifest applicationManifest
	if err := yaml.Unmarshal(data, &manifest); err != nil {
		return nil, fmt.Errorf("parse Application %s: %w", path, err)
	}

	for _, source := range manifest.Spec.Sources {
		if source.Chart == "" || source.Helm == nil {
			continue
		}

		app := &appSpec{
			Chart:          source.Chart,
			TargetRevision: source.TargetRevision,
			ReleaseName:    source.Helm.ReleaseName,
		}
		for _, ref := range source.Helm.ValueFiles {
			if !strings.HasPrefix(ref, valuesRefPrefix) {
				return nil, fmt.Errorf(
					"unsupported valueFiles entry %q in %s: only %s refs are supported",
					ref,
					path,
					valuesRefPrefix,
				)
			}
			app.ValueFiles = append(app.ValueFiles, strings.TrimPrefix(ref, valuesRefPrefix))
		}
		return app, nil
	}

	return nil, fmt.Errorf("no helm chart source found in Application %s", path)
}

// loadValues loads and helm-merges the Application's values files, resolved
// against the repo root.
func (a *appSpec) loadValues(repoRoot string) (map[string]any, error) {
	merged := map[string]any{}
	for _, rel := range a.ValueFiles {
		values, err := loadValuesFile(filepath.Join(repoRoot, rel))
		if err != nil {
			return nil, err
		}
		merged = mergeMaps(merged, values)
	}
	return merged, nil
}
