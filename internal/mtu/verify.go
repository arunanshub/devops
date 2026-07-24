// Package mtu verifies the VXLAN+WireGuard MTU stack is correctly configured.
//
// Cilium's MTU param is the physical device MTU (auto-detect = enp7s0 = 1450).
// Expected stack: enp7s0=1450 → cilium_wg0=1355 (-95 WireGuard overhead).
// The 95-byte overhead (and thus 1355) assumes Cilium >= 1.20.0-pre.3, which
// corrected WireguardOverhead to reserve the 15-byte framing padding. On
// <= 1.20.0-pre.2 the overhead was 80 and cilium_wg0 was 1370.
//
// Pod interface MTU stays at 1450; path MTU enforcement is done via PMTUD
// (packetization-layer-pmtud-mode=always) for UDP/ICMP and eBPF MSS clamping
// for TCP. Packets at the VXLAN ceiling (payload ≤ 1276b = 1304b IP) must
// pass. See docs/cilium-mtu-overlay-networking.md for the full analysis.
package mtu

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/arunanshub/devops/internal/k8s"
	"github.com/arunanshub/devops/internal/logging"
)

const (
	podNameA = "mtu-verify-a"
	podNameB = "mtu-verify-b"

	ciliumNamespace = "kube-system"
	ciliumSelector  = "k8s-app=cilium"
	ciliumContainer = "cilium-agent"
	ciliumConfigMap = "cilium-config"

	cloudflaredNamespace   = "cloudflared"
	cloudflaredSelector    = "app=cloudflared"
	cloudflaredMetricsPort = 2000

	// icmpHeaderOverhead is the IP + ICMP header size added to a ping payload.
	icmpHeaderOverhead = 28

	metricsFetchTimeout = 3 * time.Second
)

// Cluster is the set of cluster operations the verifier needs. It is
// implemented by *k8s.Client and faked in tests.
type Cluster interface {
	NodeNames(ctx context.Context) ([]string, error)
	CreatePod(ctx context.Context, spec *k8s.PodSpec) error
	WaitPodsReady(
		ctx context.Context,
		namespace string,
		names []string,
		timeout time.Duration,
	) error
	DeletePods(ctx context.Context, namespace string, names []string, waitGone bool) error
	PodIP(ctx context.Context, namespace, name string) (string, error)
	PodsByLabel(ctx context.Context, namespace, selector string) ([]k8s.PodInfo, error)
	ConfigMapData(ctx context.Context, namespace, name string) (map[string]string, error)
	Exec(
		ctx context.Context,
		namespace, pod, container string,
		command []string,
	) (stdout, stderr string, err error)
	PortForward(
		ctx context.Context,
		namespace, pod string,
		remotePort uint16,
	) (localPort uint16, stop func(), err error)
}

// Config carries the expected values for every check. The defaults live on
// the opsctl verify-mtu flags.
type Config struct {
	// Namespace the throwaway verification pods are created in.
	Namespace string
	// Image used for the verification pods; must ship ping and ip.
	Image string
	// ExpectedWgMTU is the cilium_wg0 MTU: enp7s0 1450 - WireGuard 95.
	ExpectedWgMTU int
	// ExpectedPodMTU is the pod eth0 MTU (Cilium uses the native device MTU).
	ExpectedPodMTU int
	// CeilingPayload is the ICMP payload right at the VXLAN+WireGuard path
	// ceiling: overlay clamp 1305 - 28 header - 1 byte slack = 1276.
	CeilingPayload int
	// PassPayload is an ICMP payload comfortably below the ceiling.
	PassPayload int
	// MinQuicMTU is the minimum acceptable cloudflared quic_client_mtu.
	// Expected ~1344 when pod MTU=1450; below 1300 means the pod egress path
	// is clamped too aggressively somewhere in the stack.
	MinQuicMTU int
	// ReadyTimeout bounds how long the verification pods may take to start.
	ReadyTimeout time.Duration
}

// DefaultConfig returns the expected values for this cluster's stack. The
// opsctl verify-mtu flags carry the same defaults and are the place to
// override them; keep the two in sync.
func DefaultConfig() Config {
	return Config{
		Namespace:      "default",
		Image:          "busybox:1.36",
		ExpectedWgMTU:  1355,
		ExpectedPodMTU: 1450,
		CeilingPayload: 1276,
		PassPayload:    1200,
		MinQuicMTU:     1300,
		ReadyTimeout:   90 * time.Second,
	}
}

// CheckResult is the outcome of a single named check.
type CheckResult struct {
	Name  string
	Pass  bool
	Lines []string
}

// Report aggregates every check outcome.
type Report struct {
	Results []CheckResult
}

// Passed reports whether every check passed.
func (r Report) Passed() bool {
	for _, res := range r.Results {
		if !res.Pass {
			return false
		}
	}
	return true
}

// Render writes the human-readable report to w.
func (r Report) Render(w io.Writer) {
	for _, res := range r.Results {
		fmt.Fprintf(w, "▸ %s\n", res.Name)
		for _, line := range res.Lines {
			fmt.Fprintf(w, "  %s\n", line)
		}
	}

	fmt.Fprintln(w)
	if r.Passed() {
		fmt.Fprintln(w, "✓ MTU verification passed")
	} else {
		fmt.Fprintln(w, "✗ MTU verification FAILED — see above")
	}
}

// Verifier runs the MTU verification checks against a cluster. It logs
// through the span-scoped logger carried by the context (see
// internal/logging).
type Verifier struct {
	cluster    Cluster
	cfg        Config
	httpClient *http.Client
}

// NewVerifier builds a Verifier.
func NewVerifier(cluster Cluster, cfg *Config) *Verifier {
	return &Verifier{
		cluster:    cluster,
		cfg:        *cfg,
		httpClient: &http.Client{Timeout: metricsFetchTimeout},
	}
}

// Run provisions two pinned pods on distinct nodes, executes every check, and
// tears the pods down. Setup failures return an error; check failures are
// recorded in the report.
func (v *Verifier) Run(ctx context.Context) (Report, error) {
	pods := []string{podNameA, podNameB}

	if err := v.cluster.DeletePods(ctx, v.cfg.Namespace, pods, true); err != nil {
		return Report{}, fmt.Errorf("clean up leftover verification pods: %w", err)
	}
	logging.FromContext(ctx).DebugContext(ctx, "cleaned up leftover verification pods")

	nodes, err := v.cluster.NodeNames(ctx)
	if err != nil {
		return Report{}, err
	}
	if len(nodes) < 2 {
		return Report{}, fmt.Errorf(
			"need at least 2 nodes for a cross-node test, have %d",
			len(nodes),
		)
	}

	logging.FromContext(ctx).InfoContext(ctx, "deploying test pods",
		slog.String("node_a", nodes[0]), slog.String("node_b", nodes[1]))

	for i, name := range pods {
		spec := &k8s.PodSpec{
			Name:      name,
			Namespace: v.cfg.Namespace,
			Image:     v.cfg.Image,
			Command:   []string{"sleep", "300"},
			NodeName:  nodes[i],
		}
		if err := v.cluster.CreatePod(ctx, spec); err != nil {
			return Report{}, err
		}
	}
	defer func() {
		// Cleanup must run even when ctx is already cancelled.
		cleanupCtx := context.WithoutCancel(ctx)
		if err := v.cluster.DeletePods(cleanupCtx, v.cfg.Namespace, pods, false); err != nil {
			logging.FromContext(cleanupCtx).WarnContext(
				cleanupCtx,
				"failed to clean up verification pods",
				slog.Any("error", err),
			)
		}
	}()

	if err := v.cluster.WaitPodsReady(ctx, v.cfg.Namespace, pods, v.cfg.ReadyTimeout); err != nil {
		return Report{}, err
	}
	logging.FromContext(ctx).DebugContext(ctx, "test pods ready")

	podBIP, err := v.cluster.PodIP(ctx, v.cfg.Namespace, podNameB)
	if err != nil {
		return Report{}, err
	}
	logging.FromContext(ctx).DebugContext(ctx, "resolved target pod IP", slog.String("ip", podBIP))

	return Report{Results: []CheckResult{
		runCheck(ctx, "pod-mtu", v.checkPodMTU),
		runCheck(ctx, "ping-pass", func(ctx context.Context) CheckResult {
			return v.checkCrossNodePing(ctx, podBIP, v.cfg.PassPayload, "comfortable margin")
		}),
		runCheck(ctx, "ping-ceiling", func(ctx context.Context) CheckResult {
			return v.checkCrossNodePing(ctx, podBIP, v.cfg.CeilingPayload, "path ceiling")
		}),
		runCheck(ctx, "wireguard-mtu", v.checkWireguardMTU),
		runCheck(ctx, "pmtud", v.checkPMTUD),
		runCheck(ctx, "cloudflared-quic", v.checkCloudflaredQUIC),
	}}, nil
}

// runCheck wraps a single check in a span so every log line inside it is
// tagged with the check name, and records the outcome at debug level.
func runCheck(
	ctx context.Context,
	name string,
	check func(context.Context) CheckResult,
) CheckResult {
	ctx, end := logging.Span(ctx, "check."+name)
	defer end()

	res := check(ctx)
	logging.FromContext(ctx).DebugContext(ctx, "check finished",
		slog.Bool("pass", res.Pass), slog.Any("detail", res.Lines))
	return res
}

// checkPodMTU verifies the pod interface MTU equals the native device MTU.
func (v *Verifier) checkPodMTU(ctx context.Context) CheckResult {
	res := CheckResult{Name: "pod interface MTU"}

	stdout, _, err := v.cluster.Exec(ctx, v.cfg.Namespace, podNameA, "",
		[]string{"ip", "link", "show", "eth0"})
	if err != nil {
		return failf(res, "FAIL: read pod eth0: %v ✗", err)
	}

	actual, err := linkMTU(stdout)
	if err != nil {
		return failf(res, "FAIL: %v ✗", err)
	}

	if actual != v.cfg.ExpectedPodMTU {
		return failf(res, "FAIL: pod eth0 MTU = %d, expected %d ✗", actual, v.cfg.ExpectedPodMTU)
	}
	return passf(res, "pod eth0 MTU = %d ✓", actual)
}

// checkCrossNodePing pings pod B from pod A with the given ICMP payload.
func (v *Verifier) checkCrossNodePing(
	ctx context.Context,
	targetIP string,
	payload int,
	label string,
) CheckResult {
	res := CheckResult{Name: fmt.Sprintf(
		"cross-node ping: payload=%db (packet=%db, %s)",
		payload, payload+icmpHeaderOverhead, label,
	)}

	// A lost ping makes the command exit non-zero; the loss statistics are
	// still on stdout, so parse before deciding anything about err.
	stdout, stderr, err := v.cluster.Exec(ctx, v.cfg.Namespace, podNameA, "",
		[]string{"ping", "-s", strconv.Itoa(payload), "-c", "3", "-W", "2", targetIP})
	loss := packetLossPercent(stdout + stderr)

	if loss == 0 {
		return passf(res, "%db payload → 0%% loss ✓", payload)
	}
	if err != nil {
		logging.FromContext(ctx).DebugContext(ctx, "ping failed", slog.Any("error", err))
	}
	return failf(res, "FAIL: %db payload → %d%% loss — cross-node path broken ✗", payload, loss)
}

// checkWireguardMTU verifies cilium_wg0 on every node.
func (v *Verifier) checkWireguardMTU(ctx context.Context) CheckResult {
	res := CheckResult{Name: fmt.Sprintf(
		"cilium_wg0 MTU on each node (expected: enp7s0 1450 - WG 95 = %d)", v.cfg.ExpectedWgMTU,
	)}

	pods, err := v.cluster.PodsByLabel(ctx, ciliumNamespace, ciliumSelector)
	if err != nil {
		return failf(res, "FAIL: list cilium pods: %v ✗", err)
	}
	if len(pods) == 0 {
		return failf(res, "FAIL: no cilium pods found ✗")
	}

	res.Pass = true
	for _, pod := range pods {
		stdout, _, err := v.cluster.Exec(ctx, ciliumNamespace, pod.Name, ciliumContainer,
			[]string{"ip", "link", "show", "cilium_wg0"})
		if err != nil {
			res = failf(res, "FAIL: %s: read cilium_wg0: %v ✗", pod.NodeName, err)
			continue
		}

		wgMTU, err := linkMTU(stdout)
		if err != nil {
			res = failf(res, "FAIL: %s: %v ✗", pod.NodeName, err)
			continue
		}

		if wgMTU != v.cfg.ExpectedWgMTU {
			res = failf(
				res,
				"FAIL: %s cilium_wg0 = %d, expected %d ✗",
				pod.NodeName,
				wgMTU,
				v.cfg.ExpectedWgMTU,
			)
			continue
		}
		res.Lines = append(res.Lines, fmt.Sprintf("%s cilium_wg0 = %d ✓", pod.NodeName, wgMTU))
	}
	return res
}

// checkPMTUD verifies PMTUD is enabled as the safety net for oversized
// UDP/ICMP packets.
func (v *Verifier) checkPMTUD(ctx context.Context) CheckResult {
	res := CheckResult{Name: "PMTUD enabled in Cilium configmap"}

	data, err := v.cluster.ConfigMapData(ctx, ciliumNamespace, ciliumConfigMap)
	if err != nil {
		return failf(res, "FAIL: read %s configmap: %v ✗", ciliumConfigMap, err)
	}

	enabled := data["enable-pmtu-discovery"]
	mode := data["packetization-layer-pmtud-mode"]
	if enabled != "true" || mode != "always" {
		return failf(res, "FAIL: PMTUD not active (enabled=%q, mode=%q) ✗", enabled, mode)
	}
	return passf(res, "enable-pmtu-discovery=true, mode=always ✓")
}

// checkCloudflaredQUIC verifies the egress path MTU seen by cloudflared's
// QUIC client. Missing cloudflared or unreadable metrics degrade to a
// warning, matching the shell implementation.
func (v *Verifier) checkCloudflaredQUIC(ctx context.Context) CheckResult {
	res := CheckResult{Name: "cloudflared quic_client_mtu (egress path sanity check)"}

	pods, err := v.cluster.PodsByLabel(ctx, cloudflaredNamespace, cloudflaredSelector)
	if err != nil || len(pods) == 0 {
		return passf(res, "cloudflared not found — skipping")
	}
	pod := pods[0].Name

	localPort, stop, err := v.cluster.PortForward(
		ctx,
		cloudflaredNamespace,
		pod,
		cloudflaredMetricsPort,
	)
	if err != nil {
		return passf(res, "WARN: port-forward to %s failed: %v", pod, err)
	}
	defer stop()

	metrics, err := v.fetchMetrics(ctx, localPort)
	if err != nil {
		return passf(res, "WARN: could not read cloudflared metrics: %v", err)
	}

	minMTU, found := minQuicClientMTU(metrics)
	if !found {
		return passf(res, "WARN: could not read quic_client_mtu from cloudflared metrics")
	}

	if minMTU < v.cfg.MinQuicMTU {
		return failf(
			res,
			"FAIL: quic_client_mtu min=%d < %d — pod egress MTU clamped too low ✗",
			minMTU,
			v.cfg.MinQuicMTU,
		)
	}
	return passf(res, "quic_client_mtu min=%d (threshold >=%d) ✓", minMTU, v.cfg.MinQuicMTU)
}

func (v *Verifier) fetchMetrics(ctx context.Context, port uint16) (string, error) {
	url := fmt.Sprintf("http://127.0.0.1:%d/metrics", port)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, http.NoBody)
	if err != nil {
		return "", fmt.Errorf("build metrics request: %w", err)
	}

	resp, err := v.httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("fetch metrics: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("metrics endpoint returned %s", resp.Status)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("read metrics body: %w", err)
	}
	return string(body), nil
}

func passf(res CheckResult, format string, args ...any) CheckResult {
	res.Pass = true
	res.Lines = append(res.Lines, fmt.Sprintf(format, args...))
	return res
}

func failf(res CheckResult, format string, args ...any) CheckResult {
	res.Pass = false
	res.Lines = append(res.Lines, fmt.Sprintf(format, args...))
	return res
}
