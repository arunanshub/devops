package mtu

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/arunanshub/devops/internal/k8s"
)

type fakeCluster struct {
	nodes       []string
	execOut     map[string]string
	execErr     map[string]error
	configMaps  map[string]map[string]string
	podsByLabel map[string][]k8s.PodInfo
	podIPs      map[string]string
	created     []k8s.PodSpec
	deleted     []string
}

func execKey(pod string, command []string) string {
	return pod + " " + strings.Join(command, " ")
}

func (f *fakeCluster) NodeNames(context.Context) ([]string, error) {
	return f.nodes, nil
}

func (f *fakeCluster) CreatePod(_ context.Context, spec *k8s.PodSpec) error {
	f.created = append(f.created, *spec)
	return nil
}

func (f *fakeCluster) WaitPodsReady(context.Context, string, []string, time.Duration) error {
	return nil
}

func (f *fakeCluster) DeletePods(_ context.Context, _ string, names []string, _ bool) error {
	f.deleted = append(f.deleted, names...)
	return nil
}

func (f *fakeCluster) PodIP(_ context.Context, _, name string) (string, error) {
	ip, ok := f.podIPs[name]
	if !ok {
		return "", fmt.Errorf("no IP for pod %q", name)
	}
	return ip, nil
}

func (f *fakeCluster) PodsByLabel(
	_ context.Context,
	namespace, selector string,
) ([]k8s.PodInfo, error) {
	return f.podsByLabel[namespace+"/"+selector], nil
}

func (f *fakeCluster) ConfigMapData(_ context.Context, _, name string) (map[string]string, error) {
	data, ok := f.configMaps[name]
	if !ok {
		return nil, fmt.Errorf("no configmap %q", name)
	}
	return data, nil
}

func (f *fakeCluster) Exec(
	_ context.Context,
	_, pod, _ string,
	command []string,
) (string, string, error) {
	key := execKey(pod, command)
	if err, ok := f.execErr[key]; ok {
		return f.execOut[key], "", err
	}
	out, ok := f.execOut[key]
	if !ok {
		return "", "", fmt.Errorf("unexpected exec %q", key)
	}
	return out, "", nil
}

func testConfig() Config {
	return Config{
		Namespace:      "default",
		Image:          "busybox:1.36",
		ExpectedWgMTU:  1355,
		ExpectedPodMTU: 1450,
		CeilingPayload: 1276,
		PassPayload:    1200,
		ReadyTimeout:   time.Second,
	}
}

// TestMain silences the process-wide default logger the Verifier picks up.
func TestMain(m *testing.M) {
	slog.SetDefault(slog.New(slog.DiscardHandler))
	os.Exit(m.Run())
}

func newTestVerifier(fake *fakeCluster) *Verifier {
	cfg := testConfig()
	return NewVerifier(fake, &cfg)
}

func TestCheckPMTUD(t *testing.T) {
	tests := []struct {
		name     string
		data     map[string]string
		wantPass bool
	}{
		{
			name: "enabled with always mode",
			data: map[string]string{
				"enable-pmtu-discovery":          "true",
				"packetization-layer-pmtud-mode": "always",
			},
			wantPass: true,
		},
		{
			name: "wrong mode",
			data: map[string]string{
				"enable-pmtu-discovery":          "true",
				"packetization-layer-pmtud-mode": "blackhole",
			},
			wantPass: false,
		},
		{
			name:     "keys missing",
			data:     map[string]string{},
			wantPass: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeCluster{configMaps: map[string]map[string]string{ciliumConfigMap: tt.data}}
			res := newTestVerifier(fake).checkPMTUD(t.Context())
			assert.Equal(t, tt.wantPass, res.Pass, "lines: %v", res.Lines)
		})
	}
}

func TestCheckWireguardMTU(t *testing.T) {
	wgLink := func(mtu int) string {
		return fmt.Sprintf("3: cilium_wg0: <POINTOPOINT,NOARP,UP> mtu %d qdisc noqueue", mtu)
	}
	ciliumPods := []k8s.PodInfo{
		{Name: "cilium-aaaaa", NodeName: "cp-1"},
		{Name: "cilium-bbbbb", NodeName: "cp-2"},
	}
	wgCommand := []string{"ip", "link", "show", "cilium_wg0"}

	t.Run("all nodes correct", func(t *testing.T) {
		fake := &fakeCluster{
			podsByLabel: map[string][]k8s.PodInfo{
				ciliumNamespace + "/" + ciliumSelector: ciliumPods,
			},
			execOut: map[string]string{
				execKey("cilium-aaaaa", wgCommand): wgLink(1355),
				execKey("cilium-bbbbb", wgCommand): wgLink(1355),
			},
		}
		res := newTestVerifier(fake).checkWireguardMTU(t.Context())
		assert.True(t, res.Pass, "lines: %v", res.Lines)
		assert.Len(t, res.Lines, 2)
	})

	t.Run("one node wrong fails but still reports the rest", func(t *testing.T) {
		fake := &fakeCluster{
			podsByLabel: map[string][]k8s.PodInfo{
				ciliumNamespace + "/" + ciliumSelector: ciliumPods,
			},
			execOut: map[string]string{
				execKey("cilium-aaaaa", wgCommand): wgLink(1370),
				execKey("cilium-bbbbb", wgCommand): wgLink(1355),
			},
		}
		res := newTestVerifier(fake).checkWireguardMTU(t.Context())
		assert.False(t, res.Pass)
		assert.Len(t, res.Lines, 2)
	})

	t.Run("no cilium pods fails", func(t *testing.T) {
		fake := &fakeCluster{podsByLabel: map[string][]k8s.PodInfo{}}
		res := newTestVerifier(fake).checkWireguardMTU(t.Context())
		assert.False(t, res.Pass)
	})
}

func TestCheckCrossNodePing(t *testing.T) {
	pingCommand := func(payload int) []string {
		return []string{"ping", "-s", strconv.Itoa(payload), "-c", "3", "-W", "2", "10.42.0.9"}
	}

	t.Run("zero loss passes", func(t *testing.T) {
		fake := &fakeCluster{execOut: map[string]string{
			execKey(podNameA, pingCommand(1200)): "3 packets transmitted, 3 packets received, 0% packet loss",
		}}
		res := newTestVerifier(
			fake,
		).checkCrossNodePing(t.Context(), "10.42.0.9", 1200, "comfortable margin")
		assert.True(t, res.Pass, "lines: %v", res.Lines)
	})

	t.Run("loss fails even when exec also errors", func(t *testing.T) {
		key := execKey(podNameA, pingCommand(1276))
		fake := &fakeCluster{
			execOut: map[string]string{
				key: "3 packets transmitted, 0 packets received, 100% packet loss",
			},
			execErr: map[string]error{key: errors.New("command terminated with exit code 1")},
		}
		res := newTestVerifier(
			fake,
		).checkCrossNodePing(t.Context(), "10.42.0.9", 1276, "path ceiling")
		assert.False(t, res.Pass)
	})
}

func TestCheckPodMTU(t *testing.T) {
	linkCommand := []string{"ip", "link", "show", "eth0"}

	t.Run("expected MTU passes", func(t *testing.T) {
		fake := &fakeCluster{execOut: map[string]string{
			execKey(podNameA, linkCommand): "2: eth0@if42: <UP> mtu 1450 qdisc noqueue",
		}}
		res := newTestVerifier(fake).checkPodMTU(t.Context())
		assert.True(t, res.Pass, "lines: %v", res.Lines)
	})

	t.Run("unexpected MTU fails", func(t *testing.T) {
		fake := &fakeCluster{execOut: map[string]string{
			execKey(podNameA, linkCommand): "2: eth0@if42: <UP> mtu 1305 qdisc noqueue",
		}}
		res := newTestVerifier(fake).checkPodMTU(t.Context())
		assert.False(t, res.Pass)
	})
}

func TestRunHappyPath(t *testing.T) {
	linkOut := "2: eth0@if42: <UP> mtu 1450 qdisc noqueue"
	wgOut := "3: cilium_wg0: <UP> mtu 1355 qdisc noqueue"
	pingOK := "3 packets transmitted, 3 packets received, 0% packet loss"

	fake := &fakeCluster{
		nodes:  []string{"cp-1", "cp-2", "cp-3"},
		podIPs: map[string]string{podNameB: "10.42.0.9"},
		configMaps: map[string]map[string]string{ciliumConfigMap: {
			"enable-pmtu-discovery":          "true",
			"packetization-layer-pmtud-mode": "always",
		}},
		podsByLabel: map[string][]k8s.PodInfo{
			ciliumNamespace + "/" + ciliumSelector: {{Name: "cilium-aaaaa", NodeName: "cp-1"}},
		},
		execOut: map[string]string{
			execKey(podNameA, []string{"ip", "link", "show", "eth0"}):                            linkOut,
			execKey("cilium-aaaaa", []string{"ip", "link", "show", "cilium_wg0"}):                wgOut,
			execKey(podNameA, []string{"ping", "-s", "1200", "-c", "3", "-W", "2", "10.42.0.9"}): pingOK,
			execKey(podNameA, []string{"ping", "-s", "1276", "-c", "3", "-W", "2", "10.42.0.9"}): pingOK,
		},
	}

	report, err := newTestVerifier(fake).Run(t.Context())
	require.NoError(t, err)
	assert.True(t, report.Passed())
	assert.Len(t, report.Results, 5)
	for _, result := range report.Results {
		assert.NotContains(t, result.Name, "cloudflared")
	}

	require.Len(t, fake.created, 2)
	assert.Equal(t, "cp-1", fake.created[0].NodeName)
	assert.Equal(t, "cp-2", fake.created[1].NodeName)
	// Leftover cleanup plus deferred teardown, both for both pods.
	assert.Equal(t, []string{podNameA, podNameB, podNameA, podNameB}, fake.deleted)
}

func TestRunNeedsTwoNodes(t *testing.T) {
	fake := &fakeCluster{nodes: []string{"cp-1"}}
	_, err := newTestVerifier(fake).Run(t.Context())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "at least 2 nodes")
}
