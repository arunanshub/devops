package adoption

import (
	"bytes"
	"fmt"
	"maps"
	"os"
	"strings"
	"text/template"

	"sigs.k8s.io/yaml"
)

// gotmplSuffix marks values files helmfile renders as Go templates.
const gotmplSuffix = ".gotmpl"

// loadValuesFile reads a values file into a map, rendering *.gotmpl files
// the way helmfile does (env/requiredEnv template functions).
func loadValuesFile(path string) (map[string]any, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read values file: %w", err)
	}

	if strings.HasSuffix(path, gotmplSuffix) {
		data, err = renderGotmpl(path, data)
		if err != nil {
			return nil, err
		}
	}

	values := map[string]any{}
	if err := yaml.Unmarshal(data, &values); err != nil {
		return nil, fmt.Errorf("parse values file %s: %w", path, err)
	}
	return values, nil
}

func renderGotmpl(path string, data []byte) ([]byte, error) {
	funcs := template.FuncMap{
		"env": os.Getenv,
		"requiredEnv": func(key string) (string, error) {
			value := os.Getenv(key)
			if value == "" {
				return "", fmt.Errorf("required environment variable %q is not set", key)
			}
			return value, nil
		},
	}

	tmpl, err := template.New(path).Funcs(funcs).Parse(string(data))
	if err != nil {
		return nil, fmt.Errorf("parse template %s: %w", path, err)
	}

	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, nil); err != nil {
		return nil, fmt.Errorf("render template %s: %w", path, err)
	}
	return buf.Bytes(), nil
}

// mergeMaps merges src into dst the way Helm merges values files: nested
// maps merge recursively, everything else (scalars, lists) is replaced by
// the later file. Returns the merged map; dst is not mutated.
func mergeMaps(dst, src map[string]any) map[string]any {
	out := maps.Clone(dst)
	if out == nil {
		out = map[string]any{}
	}

	for key, srcVal := range src {
		if dstMap, ok := out[key].(map[string]any); ok {
			if srcMap, ok := srcVal.(map[string]any); ok {
				out[key] = mergeMaps(dstMap, srcMap)
				continue
			}
		}
		out[key] = srcVal
	}
	return out
}

// deletePath removes a dotted path (e.g. "configs.secret.adminPassword")
// from a nested values map. Missing paths are a no-op.
func deletePath(values map[string]any, path string) {
	keys := strings.Split(path, ".")
	current := values
	for _, key := range keys[:len(keys)-1] {
		next, ok := current[key].(map[string]any)
		if !ok {
			return
		}
		current = next
	}
	delete(current, keys[len(keys)-1])
}

// pruneEmpty removes empty nested maps, so `key: {}` and an absent key
// compare equal — both render nothing in a Helm chart, and ignore-path
// deletions may leave empty parents behind.
func pruneEmpty(values map[string]any) {
	for key, val := range values {
		child, ok := val.(map[string]any)
		if !ok {
			continue
		}
		pruneEmpty(child)
		if len(child) == 0 {
			delete(values, key)
		}
	}
}
