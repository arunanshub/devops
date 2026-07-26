package nodecfg

import (
	"fmt"
	"os"
	"regexp"
)

var k3sVersionRe = regexp.MustCompile(`k3s_version\s*=\s*"([^"]+)"`)

// K3sVersionFromLocals reads the pinned k3s version out of infra/locals.tf —
// the same pin cloud-init installs, so the validation schema always matches
// what nodes actually run.
func K3sVersionFromLocals(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", path, err)
	}

	m := k3sVersionRe.FindSubmatch(data)
	if m == nil {
		return "", fmt.Errorf("no k3s_version pin found in %s", path)
	}
	return string(m[1]), nil
}
