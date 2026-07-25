package nodecfg

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const configzFixture = `{
  "kubeletconfig": {
    "evictionHard": {
      "memory.available": "500Mi",
      "imagefs.available": "5%",
      "nodefs.available": "5%"
    },
    "evictionSoft": {"memory.available": "1Gi"},
    "evictionSoftGracePeriod": {"memory.available": "2m0s"},
    "resolvConf": "/etc/rancher/k3s/resolv.conf",
    "serializeImagePulls": true
  }
}`

func declaredArgs() []string {
	return []string{
		"eviction-hard=memory.available<500Mi,imagefs.available<5%,nodefs.available<5%",
		"eviction-soft=memory.available<1Gi",
		"eviction-soft-grace-period=memory.available=2m0s",
		"resolv-conf=/etc/rancher/k3s/resolv.conf",
	}
}

func TestVerifyKubeletConfigMatches(t *testing.T) {
	findings, err := VerifyKubeletConfig(declaredArgs(), []byte(configzFixture))
	require.NoError(t, err)
	assert.Empty(t, findings)
}

func TestVerifyKubeletConfigDetectsEvictionDrift(t *testing.T) {
	declared := declaredArgs()
	declared[0] = "eviction-hard=memory.available<900Mi,imagefs.available<5%,nodefs.available<5%"

	findings, err := VerifyKubeletConfig(declared, []byte(configzFixture))
	require.NoError(t, err)
	require.Len(t, findings, 1)
	assert.Contains(t, findings[0].Problem, "900Mi")
}

func TestVerifyKubeletConfigDetectsScalarDrift(t *testing.T) {
	findings, err := VerifyKubeletConfig(
		[]string{"resolv-conf=/etc/wrong.conf", "serialize-image-pulls=false"},
		[]byte(configzFixture),
	)
	require.NoError(t, err)
	require.Len(t, findings, 2, "findings: %v", findings)
}

func TestVerifyKubeletConfigRejectsBadConfigz(t *testing.T) {
	_, err := VerifyKubeletConfig(declaredArgs(), []byte("{}"))
	require.Error(t, err)

	_, err = VerifyKubeletConfig(declaredArgs(), []byte("not json"))
	require.Error(t, err)
}

func TestDeclaredKubeletArgs(t *testing.T) {
	dir := writeConfig(t, "all/etc/rancher/k3s/config.yaml.d/eviction.yaml", `
kubelet-arg+:
  - "eviction-hard=memory.available<500Mi"
  - "resolv-conf=/etc/rancher/k3s/resolv.conf"
`)

	args, err := DeclaredKubeletArgs(dir)
	require.NoError(t, err)
	assert.Equal(t, []string{
		"eviction-hard=memory.available<500Mi",
		"resolv-conf=/etc/rancher/k3s/resolv.conf",
	}, args)
}

func TestKebabToCamel(t *testing.T) {
	assert.Equal(t, "evictionHard", kebabToCamel("eviction-hard"))
	assert.Equal(t, "resolvConf", kebabToCamel("resolv-conf"))
	assert.Equal(t, "evictionSoftGracePeriod", kebabToCamel("eviction-soft-grace-period"))
	assert.Equal(t, "v", kebabToCamel("v"))
}
