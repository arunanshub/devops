package nodecfg

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"sigs.k8s.io/yaml"
)

// Finding is one schema violation in a config file.
type Finding struct {
	File    string
	Problem string
}

func (f Finding) String() string {
	return f.File + ": " + f.Problem
}

// ValidateConfigDir walks dir for k3s config drop-ins (config.yaml.d/*.yaml)
// and validates every key against the k3s server flag set, and every
// kubelet-arg entry against the kubelet flag set.
func ValidateConfigDir(dir string, k3sFlags, kubeletFlags FlagSet) ([]Finding, error) {
	var findings []Finding

	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || filepath.Base(filepath.Dir(path)) != "config.yaml.d" {
			return nil
		}
		if ext := filepath.Ext(path); ext != ".yaml" && ext != ".yml" {
			return nil
		}

		fileFindings, err := validateFile(path, k3sFlags, kubeletFlags)
		if err != nil {
			return err
		}
		findings = append(findings, fileFindings...)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("walk %s: %w", dir, err)
	}
	return findings, nil
}

func validateFile(path string, k3sFlags, kubeletFlags FlagSet) ([]Finding, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}

	var config map[string]any
	if err := yaml.Unmarshal(data, &config); err != nil {
		return []Finding{{File: path, Problem: fmt.Sprintf("not valid YAML: %v", err)}}, nil
	}

	var findings []Finding
	for rawKey, value := range config {
		// k3s's append syntax suffixes list-valued keys with "+"
		// (kubelet-arg+); the flag name is the key without it.
		key := strings.TrimSuffix(rawKey, "+")

		if !k3sFlags.Has(key) {
			findings = append(findings, Finding{
				File: path,
				Problem: fmt.Sprintf("%q is not a flag of the pinned k3s server binary — "+
					"k3s would exit with 'unknown flag' at startup (crash loop)", key),
			})
			continue
		}

		if key == "kubelet-arg" {
			findings = append(findings, validateKubeletArgs(path, value, kubeletFlags)...)
		}
	}
	return findings, nil
}

// validateKubeletArgs checks each kubelet-arg entry ("name=value" or "name")
// against the kubelet's real CLI flags. KubeletConfiguration FIELDS are not
// necessarily FLAGS — that mismatch is exactly the crash-loop class this
// validator exists for.
func validateKubeletArgs(path string, value any, kubeletFlags FlagSet) []Finding {
	entries, ok := value.([]any)
	if !ok {
		return []Finding{
			{File: path, Problem: "kubelet-arg must be a list of \"flag=value\" strings"},
		}
	}

	var findings []Finding
	for _, entry := range entries {
		arg, ok := entry.(string)
		if !ok {
			findings = append(findings, Finding{
				File:    path,
				Problem: fmt.Sprintf("kubelet-arg entry %v is not a string", entry),
			})
			continue
		}

		name, _, _ := strings.Cut(arg, "=")
		name = strings.TrimPrefix(strings.TrimPrefix(name, "--"), "--")
		if !kubeletFlags.Has(name) {
			findings = append(findings, Finding{
				File: path,
				Problem: fmt.Sprintf("kubelet-arg %q is not a CLI flag of the pinned kubelet — "+
					"config-file-only KubeletConfiguration fields crash the kubelet as unknown flags", name),
			})
		}
	}
	return findings
}
