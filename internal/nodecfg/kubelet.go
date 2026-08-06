package nodecfg

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"sigs.k8s.io/yaml"
)

// layersForRole returns the config layers applicable to a node role.
func layersForRole(role string) (map[string]bool, error) {
	layers := map[string]bool{"all": true}
	switch role {
	case "cp_only", "cp_worker":
		layers["control-plane"] = true
	case "worker":
	default:
		return nil, fmt.Errorf("unsupported node role %q", role)
	}
	return layers, nil
}

// DeclaredKubeletArgs collects kubelet-arg entries from the config layers
// applicable to role, in file order.
func DeclaredKubeletArgs(dir, role string) ([]string, error) {
	layers, err := layersForRole(role)
	if err != nil {
		return nil, err
	}

	var args []string
	err = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || filepath.Base(filepath.Dir(path)) != "config.yaml.d" {
			return nil
		}
		rel, err := filepath.Rel(dir, path)
		if err != nil {
			return err
		}
		layer, _, _ := strings.Cut(rel, string(filepath.Separator))
		if !layers[layer] {
			return nil
		}

		fileArgs, err := kubeletArgsFromFile(path)
		if err != nil {
			return err
		}
		args = append(args, fileArgs...)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("collect kubelet args from %s: %w", dir, err)
	}
	return args, nil
}

// kubeletArgsFromFile extracts every kubelet-arg (or kubelet-arg+) entry from
// one config layer file.
func kubeletArgsFromFile(path string) ([]string, error) {
	// The walk root is the repo's own nodes/ tree, not untrusted input.
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	values := map[string]any{}
	if err := yaml.Unmarshal(data, &values); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}

	var args []string
	for key, value := range values {
		if strings.TrimSuffix(key, "+") != "kubelet-arg" {
			continue
		}
		entries, ok := value.([]any)
		if !ok {
			return nil, fmt.Errorf("%s: kubelet-arg is not a list", path)
		}
		for _, entry := range entries {
			arg, ok := entry.(string)
			if !ok {
				return nil, fmt.Errorf("%s: kubelet-arg entry %v is not a string", path, entry)
			}
			args = append(args, arg)
		}
	}
	return args, nil
}

// evictionMapFlags are kubelet flags whose value is a comma-joined map; the
// separator between key and value differs per flag.
var evictionMapFlags = map[string]string{
	"eviction-hard":              "<",
	"eviction-soft":              "<",
	"eviction-soft-grace-period": "=",
	"eviction-minimum-reclaim":   "=",
}

// VerifyKubeletConfig compares declared kubelet-args against the kubelet's
// live /configz document and returns one finding per mismatch. Field names
// map mechanically: kebab-case flag → camelCase KubeletConfiguration field
// (eviction-hard → evictionHard).
func VerifyKubeletConfig(declared []string, configz []byte) ([]Finding, error) {
	var doc struct {
		KubeletConfig map[string]any `json:"kubeletconfig"`
	}
	if err := json.Unmarshal(configz, &doc); err != nil {
		return nil, fmt.Errorf("parse configz: %w", err)
	}
	if doc.KubeletConfig == nil {
		return nil, errors.New("configz has no kubeletconfig document")
	}

	var findings []Finding
	fail := func(format string, args ...any) {
		findings = append(findings, Finding{File: "configz", Problem: fmt.Sprintf(format, args...)})
	}

	for _, arg := range declared {
		name, value, _ := strings.Cut(arg, "=")
		name = strings.TrimPrefix(strings.TrimPrefix(name, "--"), "--")
		field := kebabToCamel(name)
		got, present := doc.KubeletConfig[field]

		if sep, isMap := evictionMapFlags[name]; isMap {
			mapFindings, err := verifyMapFlag(name, field, value, sep, got)
			if err != nil {
				return nil, err
			}
			findings = append(findings, mapFindings...)
			continue
		}

		if !present {
			fail("%s: kubelet config has no %s field", name, field)
			continue
		}
		if fmt.Sprintf("%v", got) != value {
			fail("%s: declared %q, kubelet has %v", name, value, got)
		}
	}
	return findings, nil
}

// verifyMapFlag compares one comma-joined map flag (eviction-hard and
// friends) against the kubelet's live map field.
func verifyMapFlag(name, field, value, sep string, got any) ([]Finding, error) {
	want, err := parsePairs(value, sep)
	if err != nil {
		return nil, fmt.Errorf("declared %s: %w", name, err)
	}

	var findings []Finding
	fail := func(format string, args ...any) {
		findings = append(findings, Finding{File: "configz", Problem: fmt.Sprintf(format, args...)})
	}

	gotMap, ok := got.(map[string]any)
	if !ok {
		fail("%s: kubelet %s is %v, expected a map", name, field, got)
		return findings, nil
	}
	for key, wantVal := range want {
		if fmt.Sprintf("%v", gotMap[key]) != wantVal {
			fail("%s: declared %s=%s, kubelet has %v", name, key, wantVal, gotMap[key])
		}
	}
	return findings, nil
}

// parsePairs splits "a<1,b<2" (or "a=1,b=2") into a map.
func parsePairs(value, sep string) (map[string]string, error) {
	pairs := map[string]string{}
	for part := range strings.SplitSeq(value, ",") {
		key, val, found := strings.Cut(part, sep)
		if !found {
			return nil, fmt.Errorf("entry %q has no %q separator", part, sep)
		}
		pairs[key] = val
	}
	return pairs, nil
}

func kebabToCamel(kebab string) string {
	parts := strings.Split(kebab, "-")
	for i := 1; i < len(parts); i++ {
		if parts[i] != "" {
			parts[i] = strings.ToUpper(parts[i][:1]) + parts[i][1:]
		}
	}
	return strings.Join(parts, "")
}
