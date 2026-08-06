package netpolicy

import (
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"sigs.k8s.io/yaml"
)

type ciliumNetworkPolicy struct {
	Spec struct {
		Egress []egressRule `yaml:"egress"`
	} `yaml:"spec"`
}

type egressRule struct {
	ToCIDR     []string   `yaml:"toCIDR"`
	ToEntities []string   `yaml:"toEntities"`
	ToPorts    []portRule `yaml:"toPorts"`
}

type portRule struct {
	Ports []port `yaml:"ports"`
}

type port struct {
	Port     string `yaml:"port"`
	Protocol string `yaml:"protocol"`
}

func TestTraefikNetworkPolicyAllowsKubernetesAPIEntity(t *testing.T) {
	policy := readTraefikNetworkPolicy(t)

	allowed := false
	for _, rule := range policy.Spec.Egress {
		if contains(rule.ToEntities, "kube-apiserver") && allowsTCPPort(rule.ToPorts, "6443") {
			allowed = true
		}
	}

	assert.True(t, allowed,
		"Traefik must allow Kubernetes API egress via the kube-apiserver entity on TCP/6443")
}

func TestTraefikNetworkPolicyDoesNotPinKubernetesAPIToLoadBalancerIP(t *testing.T) {
	policy := readTraefikNetworkPolicy(t)

	for _, rule := range policy.Spec.Egress {
		if contains(rule.ToCIDR, "10.0.0.100/32") && allowsTCPPort(rule.ToPorts, "6443") {
			assert.Fail(t, "Traefik must not pin Kubernetes API egress to the load-balancer IP",
				"Cilium load-balancing reaches API backends directly")
		}
	}
}

func readTraefikNetworkPolicy(t *testing.T) ciliumNetworkPolicy {
	t.Helper()

	path := filepath.Join(
		"..",
		"..",
		"kubernetes",
		"components",
		"network-policies",
		"resources",
		"traefik-netpol.yaml",
	)
	raw, err := os.ReadFile(path)
	require.NoError(t, err, "read Traefik network policy")

	var policy ciliumNetworkPolicy
	require.NoError(t, yaml.Unmarshal(raw, &policy), "parse Traefik network policy")
	return policy
}

func contains(values []string, expected string) bool {
	return slices.Contains(values, expected)
}

func allowsTCPPort(rules []portRule, expected string) bool {
	for _, rule := range rules {
		for _, port := range rule.Ports {
			if port.Port == expected && port.Protocol == "TCP" {
				return true
			}
		}
	}
	return false
}
