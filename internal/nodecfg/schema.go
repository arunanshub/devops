// Package nodecfg validates the declarative node configuration under nodes/
// against the real flag schemas of the pinned k3s and kubelet binaries — the
// only schema oracle that cannot drift from what runs on the nodes.
//
// This exists because a k3s config key or kubelet-arg that isn't a real CLI
// flag is rejected at RUNTIME with a crash loop; no amount of YAML linting
// catches it (see memory: 26 k3s restarts on cp-1, 2026-06-19, from
// --max-parallel-image-pulls — a KubeletConfiguration field, not a flag).
package nodecfg

import (
	"fmt"
	"regexp"
	"strings"
)

// FlagSet is the set of valid flag names extracted from a binary's --help.
type FlagSet map[string]struct{}

// Has reports whether name is a known flag.
func (f FlagSet) Has(name string) bool {
	_, ok := f[name]
	return ok
}

// flagRe matches long-form flag definitions in help output. Both formats in
// play define flags at line start after whitespace:
//
//	k3s (urfave/cli):  `   --etcd-expose-metrics      (db) Expose ...`
//	kubelet (cobra):   `      --eviction-hard mapStringString   A set ...`
var flagRe = regexp.MustCompile(`^\s*(?:-[a-zA-Z0-9], )?--([a-z0-9][a-z0-9-]*)`)

// ParseHelpFlags extracts the flag names from a --help output.
func ParseHelpFlags(help string) FlagSet {
	flags := FlagSet{}
	for line := range strings.SplitSeq(help, "\n") {
		if m := flagRe.FindStringSubmatch(line); m != nil {
			flags[m[1]] = struct{}{}
		}
	}
	return flags
}

// KubeletVersion derives the upstream kubernetes version embedded in a k3s
// release: v1.36.2+k3s1 → v1.36.2.
func KubeletVersion(k3sVersion string) (string, error) {
	version, _, found := strings.Cut(k3sVersion, "+")
	if !found || !strings.HasPrefix(version, "v") {
		return "", fmt.Errorf("k3s version %q does not look like v<semver>+k3s<n>", k3sVersion)
	}
	return version, nil
}
