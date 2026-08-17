# Cilium WireGuard FQ Latency Investigation

## Goal

Find the cause of the latency tail on `arunanshu.dev`.

Use evidence to select one small fix.

Do not make a production change until an experiment proves its benefit.

## Scope

The request path is:

```text
browser -> Cloudflare edge -> cloudflared -> Traefik -> arunanshu-dev
```

Some requests cross the Cilium VXLAN and WireGuard path.

## Safety rules

- Use read-only checks first.
- Use the private cluster path for origin tests.
- Do not load-test the public Cloudflare route.
- Use existing pods for low-rate probes.
- Create only one restricted temporary probe pod at a time.
- Reuse a pinned image and an existing restricted security context.
- Run one temporary test at a time.
- Remove temporary test resources before the next test.
- Do not alter Cilium, cloudflared, Traefik, or node sysctls without a passed gate.
- Do not run a test during a node upgrade, rollout, or incident.
- Stop a test if any readiness check fails or an alert fires.

## Decision standard

Treat a fix as valid only when all conditions are true:

1. The experiment changes one factor.
2. The experiment has a baseline and a control.
3. The experiment records p50, p95, p99, errors, packet drops, and CPU.
4. The experiment improves the tail without increasing errors or drops.
5. The result repeats in two separate windows.

## Current baseline

The baseline came from live checks on 2026-08-17.

| Signal | Result | Interpretation |
| --- | --- | --- |
| Cilium health | Three of three nodes reachable | The basic datapath is healthy. |
| Cross-node MTU | 0% loss at the 1304-byte ceiling | The MTU calculation is valid. |
| `cilium_wg0` transmit drops, six hours | 13,195 of 14,126,002 packets | The counter needs a kernel drop-site trace before classification. |
| QUIC event | All four automatic connections timed out at 13:17 UTC | The tunnel is not continuously reliable. |
| QUIC recovery | Six to eleven seconds | In-flight requests can fail or stall. |
| Tunnel errors | 27 on one automatic-protocol pod | The fixed HTTP/2 pod recorded zero. |
| Traefik, six hours | p50 9 ms, p95 287 ms, p99 457 ms | The normal origin path is fast. |
| App resources | Peak CPU below 0.026 core and memory below 130 MiB | App saturation is not the current cause. |

The response-code and total-request counters have different grains.

Do not calculate an availability rate from those counters.

## Established facts

### Server Actions

The three-action example starts three 300 ms Server Actions.

Next dispatches them one at a time for one client.

The minimum completion time is about 900 ms before network overhead.

Do not use this example as a network latency probe.

Use a single action or the plain HTTP `/rpc` read path for latency tests.

### Cilium

The rendered Cilium configuration matches the live ConfigMap.

The active settings include VXLAN, WireGuard, strict pod encryption, BBR, bandwidth manager, and PMTUD.

Each node has two WireGuard peers.

Each node has `net.core.rmem_max=7500000`.

The receive-buffer change did not stop the observed QUIC timeout.

A live packet capture disproved one repository assumption.

WireGuard uses private IPv4 between the nodes on `enp7s0`.

The capture showed UDP port 51871 traffic between `10.0.0.2` and `10.0.0.4`.

WireGuard does not use the public IPv6 path in the current cluster.

### Tunnel transport

Two cloudflared pods use `--protocol auto`.

One cloudflared pod uses `--protocol http2`.

The fixed HTTP/2 pod is not an independent request route.

Cloudflare distributes requests across all connectors of the same tunnel.

The fixed HTTP/2 pod has no placement rule. It shares cp-2 with one automatic pod.

The split does not isolate an edge-path failure.

### Policy boundary

The `arunanshu-dev` namespace has no Kubernetes NetworkPolicy.

No CiliumClusterwideNetworkPolicy exists.

The Traefik Cilium policy permits egress to the `arunanshu-dev` namespace.

The cloudflared policy permits DNS, port 7844 to the Cloudflare CIDRs, and Traefik port 8000.

The E2 probe reached both internal Services and got a 400 application response.

Therefore policy enforcement did not block the probe paths.

The E2 probe did not traverse cloudflared.

Do not use E2 to rule out a cloudflared egress-policy fault.

No `POLICY_DENIED` Hubble event appeared in the six-hour metric window.
This evidence does not prove that policy cannot cause a later tunnel failure.

## Experiments

### E0: Preserve an evidence window

**Purpose:** Create a comparable baseline before each other experiment.

**Method:**

1. Record the current pod placement and restart count.
2. Record Cilium health and WireGuard peer count.
3. Record the tunnel connection count by pod.
4. Record the 5-minute and 30-minute values for packet drops and tunnel errors.
5. Record Traefik p50, p95, and p99 for `arunanshu-dev`.

**Pass condition:** All components are Ready and no rollout is active.

**Stop condition:** Any component is unavailable or a counter resets.

**Status:** Complete for the first baseline.

### E1: Separate application serialization from transport latency

**Purpose:** Prove which user interaction the measurement represents.

**Method:**

1. Use the three-action page as a negative control.
2. Measure one 300 ms Server Action from one browser client.
3. Measure three concurrent 300 ms `/rpc` reads from the same browser client.
4. Record browser request start and response end times.
5. Repeat each case 20 times without a rollout.

**Expected result:**

- Three Server Actions take about 900 ms or more.
- Three `/rpc` reads take about one 300 ms wait plus transport overhead.

**Decision:**

- If one action has a one-second tail, continue with E2 through E5.
- If only three actions have a one-second tail, reject a network fix.

**Status:** Source inspection proves the negative control. Browser measurement remains pending.

### E2: Measure the private origin path

**Purpose:** Exclude Cloudflare edge routing and browser-network variance.

**Method:**

1. Run 30 low-rate requests from each existing `arunanshu-dev` pod.
2. Measure the direct Service path.
3. Measure the Traefik Service path with `Host: arunanshu.dev`.
4. Use one static health object and one uncached `/rpc` read.
5. Record DNS, connect, first-byte, and total durations.

The application containers are distroless. They have no shell or HTTP client.

Use one short-lived `curlimages/curl` pod instead of changing an application image.

Use the pinned image and the restricted security context from `purge-cache-job.yaml`.

Disable its ServiceAccount token. Set a 64 MiB memory limit. Delete the pod after each sample set.

**Control:** The direct Service path.

**Pass condition:** The Traefik path adds less than 20 ms at p99.

**Stop condition:** Any request error, pod restart, or p99 above 500 ms.

**Status:** Partially complete.

**Experiment update:** The existing application containers cannot run an HTTP probe.
The temporary-pod control above replaces that unavailable method.

**Calibration result:** The first 60 calls returned HTTP 400 in 7 to 14 ms.
The body lacked the oRPC serializer envelope, so the handler did not run.
The test stopped and the probe pod was deleted. These values are not latency data.

**Valid internal result:** A restricted probe on cp-2 sent 15 valid requests to each path.

| Path | Success | Total p50 | Total p95 and p99 | Range |
| --- | --- | ---: | ---: | ---: |
| Direct app Service | 15 of 15 | 110.6 ms | 114.0 ms | 106.9 to 114.0 ms |
| Traefik Service | 15 of 15 | 110.5 ms | 116.8 ms | 108.5 to 116.8 ms |

Each request included the 100 ms uncached RPC handler delay.

The Traefik path added no more than 7 ms in this window.

E2 passes for this low-rate, cross-node sample.
It does not prove that an intermittent network fault cannot occur later.

**Public result:** At 15:42 UTC, 15 valid external RPC reads completed before the operator link failed.
The handler waits 100 ms. The observed end-to-end total time ranged from 547 ms to 2.566 s.
The median was 963 ms. The observed p95 and p99 were 2.566 s.

Every returned HTTP 200. The test had no retry.

This result disproves reliable 300 ms end-to-end latency for this probe source.
It does not isolate the client network, Cloudflare edge, tunnel, or origin as the cause.

The full 30-sample result is invalid because the operator link failed before output capture.

### E3: Correlate drops with latency

**Purpose:** Test whether `cilium_wg0` drops produce request tails.

**Method:**

1. Run E2 in five-minute windows.
2. Record transmit packets and drops per node for the same window.
3. Record Traefik request histograms for the same window.
4. Record cloudflared request errors and HA connections by pod.
5. Compare quiet and high-drop windows.

**Decision:**

- If p99 rises with drops on a request-path node, treat packet loss as causal evidence.
- If p99 stays flat across repeated high-drop windows, treat the drops as a separate fault.

**Status:** Complete for the drop-site classification.

The QUIC event and the WireGuard drops are separate faults.

The QUIC connector uses the node internet path.

The WireGuard drop occurs on the private node path.

### E4: Classify automatic tunnel failures

**Purpose:** Determine whether `--protocol auto` changes protocol or loses service during a flap.

**Method:**

1. Read each cloudflared pod log directly.
2. Accept `Registered tunnel connection` JSON as the protocol source.
3. Record connection index, protocol, edge location, failure time, and recovery time.
4. Compare automatic-pod errors with the fixed HTTP/2 pod.
5. Correlate each event with E3 counters.

**Decision:**

- If only automatic pods fail in repeated windows, test a dedicated HTTP/2 canary.
- If both protocols fail together, investigate the shared node and Cilium path first.

**Status:** Complete for one event.

All four QUIC connections on both automatic pods timed out at 13:17:15 and 13:17:16 UTC.

The HTTP/2 pod lost two connections at 13:17:30 and 13:17:34 UTC.
It re-registered them by 13:17:50 UTC and retained other connections.

The HTTP/2 pod had zero request errors. One automatic pod had 27 request errors in six hours.

This result proves a shared tunnel-edge fault. It does not prove that HTTP/2 removes the fault.

### E5: Validate the full packet path under safe load

**Purpose:** Find a size-dependent or rate-dependent Cilium fault.

**Method:**

1. Run `just cluster-verify` and `just verify-mtu` sequentially.
2. Run a bounded, in-cluster request test at one request per second.
3. Keep the test below 5% of the measured healthy request capacity.
4. Use cross-node source and destination pods.
5. Test 1 KiB, 16 KiB, and 128 KiB responses.
6. Record packet drops, retransmits, p99, and CPU.

**Control:** Same-node requests with the same payloads.

**Pass condition:** No size-dependent p99 increase and no increase in transmit-drop rate.

**Status:** Complete.

**Initial controlled result:** A restricted cp-1 pod sent 10 MiB of TCP data to cp-2.

The stream added eight WireGuard transmit drops and no sampled TCP retransmissions.

This result did not classify the counter. Background traffic could increment it.

**High-rate reproduction:** A 100 MiB cross-node TCP stream added 48 WireGuard transmit drops and 77 retransmitted TCP segments.

The next run added 89 WireGuard transmit drops and 107 retransmitted TCP segments.

The second run recorded exactly 89 kernel `QDISC_DROP` events.

The kernel stack was:

```text
__dev_xmit_skb
__dev_queue_xmit
udp_tunnel_xmit_skb
wg_socket_send_skb_to_peer
wg_packet_tx_worker
```

The WireGuard driver queue-overflow probe recorded zero calls.

The WireGuard peer-purge probe recorded zero calls.

The physical `enp7s0` qdisc reported `flows_plimit` drops.

The active qdisc was `fq` with `flow_limit 100p`.

This result proves real loss below WireGuard and above the private physical interface.

### E6: Dedicated tunnel transport canary

**Purpose:** Test QUIC against HTTP/2 without moving production traffic.

**Method:**

1. Create a separate hostname and separate tunnel token.
2. Route the hostname to the existing Traefik Service.
3. Run one QUIC connector and one fixed HTTP/2 connector.
4. Send one request per second from an external probe location.
5. Measure connection churn, error rate, and p99 for 24 hours.
6. Delete the canary after the result is recorded.

**Safety:** The canary has separate credentials and no production hostname.

**Decision:**

- If HTTP/2 removes the tail and QUIC does not, pin the production connectors to HTTP/2.
- If both protocols tail together, reject a protocol-only fix.

**Status:** Not started. This needs an approved Cloudflare and GitOps change.

### E7: Controlled GSO experiment

**Purpose:** Test whether GSO causes WireGuard transmit drops.

**Status:** Rejected on the production cluster.

**Reason:** Cilium is a cluster-wide DaemonSet on three control-plane nodes.

A per-node GSO change can affect production pod traffic.

The current evidence does not establish GSO as the cause.

Run this test only in a disposable three-node cluster or an approved maintenance window.

**Required measurements:** Drop rate, retransmits, p99, throughput, CPU, and recovery time.

### E8: Trace the WireGuard transmit-drop source

**Purpose:** Identify the exact kernel code that increments the observed drop counter.

**Method:**

1. Use a privileged temporary pod on cp-1.
2. Read the running WireGuard module from the node.
3. Map the driver drop instructions with `objdump`.
4. Trace peer purge, staged-queue overflow, qdisc drops, and transmit return codes.
5. Run a bounded 100 MiB cross-node TCP stream.
6. Remove all probes and temporary pods.

**Status:** Complete.

The driver did not purge a peer or overflow its staged packet queue.

The network core dropped the outer WireGuard UDP packets in `__dev_xmit_skb`.

The `fq` qdisc on `enp7s0` used the kernel default `flow_limit 100p`.

WireGuard sends each peer through one UDP flow.

The qdisc dropped bursts when that one flow reached 100 queued packets.

The Cilium bandwidth manager installed and reconciled this qdisc.

Temporary `flow_limit` changes did not persist.

During one test, cp-1 changed from qdisc handle `8b43` to `8b4c`.

During the same test, cp-2 changed from handle `8b4c` to `8b55`.

Both replacement qdiscs returned to `flow_limit 100p`.

This reconciliation rejects a permanent manual qdisc override.

### E9: Audit every explicit Cilium Helm setting

**Purpose:** Find interacting chart settings and avoid a partial fix.

**Chart:** Cilium 1.20.0.

**Method:**

1. Read the full Argo CD values file.
2. Read the full bootstrap values template.
3. Read the 1.20.0 chart defaults and JSON schema.
4. Render the chart with each values file.
5. Compare the bootstrap and Argo CD render through `just verify-adoption`.
6. Check the live ConfigMap and the live qdisc state.

| Explicit setting | Review result |
| --- | --- |
| `kubeProxyReplacement` | Required because k3s disables kube-proxy. Keep it. |
| `k8sServiceHost` and `k8sServicePort` | Point to the private API load balancer. Keep them. |
| `ipam.mode` | Uses Kubernetes IPAM. It does not cause the qdisc fault. |
| `routingMode` and `tunnelProtocol` | VXLAN carries pod CIDRs. Keep them. |
| `updateStrategy.type` | `RollingUpdate` permits the required one-node sequence. Keep it. |
| `updateStrategy.rollingUpdate.maxUnavailable` | The value `1` preserves two agents. Keep it. |
| `encryption.enabled` and `encryption.type` | WireGuard protects cross-node pod traffic. Keep both values. |
| `encryption.nodeEncryption` | The control-plane label makes this value a no-op. Remove it only in the planned Cilium deprecation change. |
| `encryption.wireguard.persistentKeepalive` | Keeps idle peer state. It does not cause the drop. |
| `encryption.strictMode.egress.enabled` | Strict egress blocks plaintext cross-node pod traffic. Keep it. |
| `encryption.strictMode.egress.cidr` | The value covers the complete IPv4 pod CIDR. Keep it. |
| `encryption.strictMode.egress.allowRemoteNodeIdentities` | VXLAN needs the remote-node exception. Keep it. |
| `encryption.strictMode.ingress.enabled` | Strict ingress blocks plaintext cross-node pod traffic. Keep it. |
| `bpf.masquerade` | Handles egress translation. Keep it. |
| `bandwidthManager.enabled` | Installs the faulty `fq` qdisc. Disable it. |
| `bandwidthManager.bbr` | Requires the bandwidth manager. Disable it. |
| `bandwidthManager.bbrHostNamespaceOnly` | Keep it false. The cluster does not need host BBR. |
| `pmtuDiscovery.enabled` | PMTUD returns feedback for oversized packets. Keep it. |
| `pmtuDiscovery.packetizationLayerPMTUDMode` | The `always` mode matches the verified overlay design. Keep it. |
| `extraConfig.enable-gateway-api` | Traefik owns Gateway API. Keep it false. |
| `extraConfig.enable-gateway-api-secrets-sync` | Cilium does not own Gateway secrets. Keep it false. |
| Three bandwidth-manager `extraConfig` keys | Force omitted stale ConfigMap keys to false. Add all three keys. |
| Agent `resources.requests.cpu` and `memory` | The agents are not resource-starved. Keep both requests. |
| `policyAuditMode` | Policy enforcement works. Keep it false. |
| `operator.replicas` | Two replicas preserve operator service during one pod loss. Keep it. |
| Operator CPU and memory requests | Current use does not show operator pressure. Keep both requests. |
| Operator memory limit | The limit matches the VPA ceiling. Keep it. |
| Operator Prometheus and ServiceMonitor | Both settings provide operator metrics. Keep them. The bootstrap omission is intentional. |
| `envoy.enabled` | No Cilium L7 policy uses Envoy. Keep it false. |
| Agent Prometheus and ServiceMonitor | Both settings provide agent metrics. Keep them. The bootstrap omission is intentional. |
| `gatewayAPI` | Traefik owns Gateway API. Keep it false. |
| `cgroup.autoMount.enabled` | The host already mounts cgroup v2. Keep it false. |
| `cgroup.hostRoot` | The value points at the host cgroup v2 mount. Keep it. |
| `hubble.relay.enabled` and its memory limit | Relay provides cluster flow queries. Keep both values. |
| `hubble.ui.enabled` and both UI memory limits | The UI uses Relay. Keep all three values. |
| `hubble.tls.auto.method` | The `cronJob` method gives deterministic certificates. Keep it. |
| Five `hubble.metrics.enabled` entries | Drop, TCP, flow, ICMP, and DNS metrics support this investigation. Keep every entry. |
| Hubble metrics ServiceMonitor | Prometheus needs this setting. Keep it. The bootstrap omission is intentional. |
| Hubble dashboards and namespace | Both values install the dashboards in `monitoring`. Keep them. |

**Result:** Only the bandwidth manager and BBR require a configuration change.

The chart omits the ConfigMap keys when the manager is disabled.

Use `extraConfig` to render all three agent keys as false.

## Rejected shortcuts

| Shortcut | Rejection reason | Required evidence before reconsideration |
| --- | --- | --- |
| Treat HTTP/2 as the complete fix | HTTP/2 reduces QUIC failures. It cannot remove the shared edge-path fault. | Measure error rate and p99 after the rollout. |
| Disable GSO | It changes a core datapath optimization without a causal result. | E7 succeeds in a disposable cluster. |
| Lower the pod MTU again | The 1304-byte ceiling already passes with 0% loss. Lowering it reduces capacity. | E5 finds a size-dependent failure. |
| Add retries to the app | It can mask loss and increase tail latency. | E3 proves a transient request failure that needs bounded retries. |
| Increase replicas | The two current app pods are idle. It does not fix a transport fault. | E2 or E5 shows app saturation. |
| Treat Hubble drops as WireGuard drops | The metrics observe different layers. | A documented metric mapping proves equivalence. |
| Increase `fq` `flow_limit` | Cilium replaces manual qdisc changes. A larger queue also hides the unused feature. | Do not reconsider. Disable the manager. |
| Manage `tc qdisc` with a node script | Cilium owns the same qdisc and causes an ownership conflict. | Do not reconsider. Keep one owner. |
| Replace `fq` with `fq_codel` manually | Cilium reconciles `fq`. The cluster does not use pod bandwidth limits. | Disable the unused manager instead. |

## Conclusion and fix

The system has two independent network faults.

The Cloudflare tunnel path has edge connection churn.

QUIC lost all eight automatic connections during one event.

HTTP/2 also lost two connections, but it kept other connections and recorded no request errors.

Use one Cloudflared Deployment with three fixed HTTP/2 replicas.

Remove the temporary HTTP/2 Deployment and VPA.

Use one selector in the Service, PDB, policy, and alert.

The cluster private path has a Cilium bandwidth-manager fault.

The bandwidth manager installs `fq` on `enp7s0`.

WireGuard carries each peer through one UDP flow on this interface.

The default 100-packet flow limit drops burst packets.

These drops cause TCP retransmissions and latency variation for cross-node traffic.

Disable `bandwidthManager.enabled`, `bandwidthManager.bbr`, and `bandwidthManager.bbrHostNamespaceOnly`.

Force the three generated ConfigMap keys to false through `extraConfig`.

Apply the same values to the bootstrap and Argo CD files.

After Argo CD syncs the ConfigMap, restart one Cilium agent at a time.

The old qdisc and congestion-control sysctl can remain until a node reboot.

Reboot one node at a time to preserve the etcd quorum.

After each node, verify Cilium health, the MTU chain, the qdisc, and cross-node retransmissions.

The desired post-reboot qdisc must not be Cilium-managed `fq`.

Do not use a manual qdisc override as the fix.

## Experiment log

| Date and time UTC | Experiment | Result | Use in decision |
| --- | --- | --- | --- |
| 2026-08-17, baseline | E0 | Cluster health and MTU checks passed. Kernel drops and QUIC flaps remain. | Run E2 and E3. |
| 2026-08-17, 13:17 | E4 | Automatic QUIC connections timed out. Fixed HTTP/2 had no errors. | Correlate with E3. |
| 15:40 | E2 malformed RPC calibration | 60 HTTP 400 responses. Probe deleted. | Reject the data. The handler did not run. |
| 15:42 | E2 valid direct RPC check | HTTP 200. The handler waited 100 ms. | The serializer envelope is correct. |
| 15:42 | External low-rate RPC probe | 15 HTTP 200 responses. Total time: 547 ms to 2.566 s. | The full path has a large latency tail. The sample is incomplete. |
| 15:53 | Post-probe health check | All nodes and request-path pods Ready. No new tunnel failure log. | The probe did not cause an outage. |
| 15:56 | E2 direct app Service | 15 of 15 HTTP 200. Total p99 114.0 ms. | The cross-node app path is healthy in this window. |
| 15:56 | E2 Traefik Service | 15 of 15 HTTP 200. Total p99 116.8 ms. | Traefik adds at most 7 ms in this window. |
| 13:17 to 13:18 | E4 full transport review | QUIC lost all eight connections. HTTP/2 lost two of four connections, but had no request errors. | A shared edge-path event affects both transports. HTTP/2 is only a mitigation. |
| Current | E5 bounded TCP transfer | 10 MiB added eight WireGuard drops but no TCP retransmits. | Treat this sample as inconclusive. Run a kernel trace. |
| 16:33 | E8 driver trace | The WireGuard peer-purge and queue-overflow probes recorded zero calls. | Exclude the WireGuard driver queues. |
| 16:35 | E8 qdisc trace | The qdisc and WireGuard counters each added 89 drops. TCP added 107 retransmitted segments. | Classify the drops as real packet loss. |
| 16:39 | E8 qdisc inspection | `enp7s0` used `fq` with `flow_limit 100p` and `flows_plimit` drops. | Identify the immediate cause. |
| 16:46 | WireGuard endpoint capture | UDP port 51871 used private IPv4 on `enp7s0`. | Disprove the public-IPv6 assumption. |
| 16:52 | E8 reconciliation check | Cilium replaced both temporary qdisc settings and restored 100 packets. | Reject a manual limit change. |
| Current | E9 Helm audit | Only the bandwidth manager and BBR create the faulty qdisc. | Disable both features in both values files. |
