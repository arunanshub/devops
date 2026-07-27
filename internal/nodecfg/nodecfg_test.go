package nodecfg

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Help-output fixtures captured verbatim from the real binaries
// (k3s v1.36.2+k3s1 `server --help`, kubelet v1.36.2 `--help`).
const (
	k3sHelpFixture = `OPTIONS:
   --config FILE, -c FILE                    (config) Load configuration from FILE [$K3S_CONFIG_FILE]
   --etcd-expose-metrics                     (db) Expose etcd metrics to client interface (default: false)
   --etcd-s3-config-secret value             (db) Name of secret in the kube-system namespace
   --embedded-registry                       (components) Enable embedded distributed container registry
   --kubelet-arg value [ --kubelet-arg value ]  (agent/flags) Customized flag for kubelet process
   --etcd-s3                                 (db) Enable backup to S3
   --etcd-snapshot-schedule-cron value       (db) Snapshot interval time in cron spec
   --etcd-snapshot-retention value           (db) Number of snapshots to retain (default: 5)
   --etcd-s3-retention value                 (db) Number of S3 snapshots to retain
   --etcd-snapshot-compress                  (db) Compress etcd snapshot
`
	kubeletHelpFixture = `Flags:
      --eviction-hard mapStringString           A set of eviction thresholds (DEPRECATED)
      --eviction-soft mapStringString           A set of eviction thresholds (DEPRECATED)
      --eviction-soft-grace-period mapStringString  A set of eviction grace periods (DEPRECATED)
      --resolv-conf string                      Resolver configuration file (DEPRECATED)
      --serialize-image-pulls                   Pull images one at a time (default true)
  -v, --v Level                                 number for the log level verbosity
`
)

func TestParseHelpFlagsBothFormats(t *testing.T) {
	k3s := ParseHelpFlags(k3sHelpFixture)
	assert.True(t, k3s.Has("etcd-expose-metrics"))
	assert.True(t, k3s.Has("kubelet-arg"))
	assert.True(t, k3s.Has("config"))
	assert.False(t, k3s.Has("not-a-flag"))

	kubelet := ParseHelpFlags(kubeletHelpFixture)
	assert.True(t, kubelet.Has("eviction-hard"))
	assert.True(t, kubelet.Has("serialize-image-pulls"))
	assert.True(t, kubelet.Has("v"), "short+long form line must still parse")
	// The June 2026 incident flag: a KubeletConfiguration FIELD, not a flag.
	assert.False(t, kubelet.Has("max-parallel-image-pulls"))
}

func writeConfig(t *testing.T, rel, content string) string {
	t.Helper()
	dir := t.TempDir()
	full := filepath.Join(dir, rel)
	require.NoError(t, os.MkdirAll(filepath.Dir(full), 0o755))
	require.NoError(t, os.WriteFile(full, []byte(content), 0o644))
	return dir
}

func testFlagSets() (FlagSet, FlagSet) {
	return ParseHelpFlags(k3sHelpFixture), ParseHelpFlags(kubeletHelpFixture)
}

func TestValidateConfigDirAcceptsValidConfig(t *testing.T) {
	dir := writeConfig(t, "all/etc/rancher/k3s/config.yaml.d/eviction.yaml", `
kubelet-arg+:
  - "eviction-hard=memory.available<500Mi"
  - "eviction-soft=memory.available<1Gi"
`)
	k3sFlags, kubeletFlags := testFlagSets()

	findings, err := ValidateConfigDir(dir, k3sFlags, kubeletFlags)
	require.NoError(t, err)
	assert.Empty(t, findings)
}

// TestValidateCatchesJuneIncident is the regression test for 2026-06-19:
// --max-parallel-image-pulls crash-looped k3s (26 restarts) because it is a
// KubeletConfiguration field, not a CLI flag. This validator must fail it.
func TestValidateCatchesJuneIncident(t *testing.T) {
	dir := writeConfig(t, "all/etc/rancher/k3s/config.yaml.d/pulls.yaml", `
kubelet-arg+:
  - "max-parallel-image-pulls=3"
  - "serialize-image-pulls=false"
`)
	k3sFlags, kubeletFlags := testFlagSets()

	findings, err := ValidateConfigDir(dir, k3sFlags, kubeletFlags)
	require.NoError(t, err)
	require.Len(t, findings, 1, "only the non-flag entry must be rejected")
	assert.Contains(t, findings[0].Problem, "max-parallel-image-pulls")
}

func TestValidateRejectsUnknownK3sKey(t *testing.T) {
	dir := writeConfig(t, "cp/etc/rancher/k3s/config.yaml.d/typo.yaml",
		"etcd-expose-metricz: true\n")
	k3sFlags, kubeletFlags := testFlagSets()

	findings, err := ValidateConfigDir(dir, k3sFlags, kubeletFlags)
	require.NoError(t, err)
	require.Len(t, findings, 1)
	assert.Contains(t, findings[0].Problem, "etcd-expose-metricz")
}

func TestValidateStripsAppendSuffix(t *testing.T) {
	dir := writeConfig(t, "all/etc/rancher/k3s/config.yaml.d/ok.yaml",
		"etcd-s3: true\netcd-snapshot-retention: 24\n")
	k3sFlags, kubeletFlags := testFlagSets()

	findings, err := ValidateConfigDir(dir, k3sFlags, kubeletFlags)
	require.NoError(t, err)
	assert.Empty(t, findings)
}

func TestValidateIgnoresFilesOutsideConfigDir(t *testing.T) {
	dir := writeConfig(t, "all/etc/rancher/k3s/registries.yaml",
		"mirrors:\n  \"*\":\n")
	k3sFlags, kubeletFlags := testFlagSets()

	findings, err := ValidateConfigDir(dir, k3sFlags, kubeletFlags)
	require.NoError(t, err)
	assert.Empty(t, findings, "registries.yaml is not a config.yaml.d drop-in")
}

func TestValidateRejectsInvalidYAML(t *testing.T) {
	dir := writeConfig(t, "all/etc/rancher/k3s/config.yaml.d/broken.yaml",
		"key: [unclosed\n")
	k3sFlags, kubeletFlags := testFlagSets()

	findings, err := ValidateConfigDir(dir, k3sFlags, kubeletFlags)
	require.NoError(t, err)
	require.Len(t, findings, 1)
	assert.Contains(t, findings[0].Problem, "YAML")
}

func TestKubeletVersion(t *testing.T) {
	version, err := KubeletVersion("v1.36.2+k3s1")
	require.NoError(t, err)
	assert.Equal(t, "v1.36.2", version)

	_, err = KubeletVersion("1.36.2")
	require.Error(t, err)
}

func TestK3sVersionFromLocals(t *testing.T) {
	dir := t.TempDir()
	locals := filepath.Join(dir, "locals.tf")
	require.NoError(t, os.WriteFile(locals, []byte(`locals {
  k3s_version  = "v1.36.2+k3s1"
  cluster_name = "hetzner-k3s"
}`), 0o644))

	version, err := K3sVersionFromLocals(locals)
	require.NoError(t, err)
	assert.Equal(t, "v1.36.2+k3s1", version)
}

func TestChecksumFor(t *testing.T) {
	hash := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

	got, err := checksumFor(hash+"\n", "")
	require.NoError(t, err)
	assert.Equal(t, hash, got)

	sums := hash + "  k3s\n" + "ffff" + hash[4:] + "  k3s-arm64\n"
	got, err = checksumFor(sums, "k3s")
	require.NoError(t, err)
	assert.Equal(t, hash, got)

	_, err = checksumFor(sums, "missing")
	require.Error(t, err)

	_, err = checksumFor("not-a-hash\n", "")
	require.Error(t, err)
}
