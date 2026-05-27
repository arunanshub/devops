# Cilium MTU and Overlay Networking

What happened, what we fixed, and why things work the way they do. Read this before touching Cilium config, investigating network drops, or after a fresh bootstrap.

---

## Assumptions

This doc is specific to this cluster's setup. The numbers only apply if all of the following hold:

- Hetzner Cloud private network (MTU 1450)
- Cilium tunnel mode: VXLAN
- Cilium WireGuard node encryption enabled, **using IPv6 as the outer transport** (cilium_wg0 overhead = 80 bytes; if Cilium were using IPv4 for the outer tunnel, the overhead would be 60 bytes and cilium_wg0 MTU would be 1390 instead of 1370)
- kube-proxy replacement enabled
- Cilium is the sole CNI — no chaining with another CNI

If any of these differ on a future cluster, redo the byte arithmetic before copying numbers from this doc.

---

## Three MTU concepts you need to keep separate

Before anything else: there are three different things called "MTU" that behave differently.

**Interface MTU.** The ceiling the kernel enforces at layer 2. If a socket tries to send a packet larger than the interface MTU, the kernel either fragments it (if allowed) or returns an error (if the DF "Don't Fragment" bit is set). Setting `eth0 mtu 1450` means no single packet leaving `eth0` exceeds 1450 bytes.

**Route MTU.** A hint stored on a specific route entry, like `10.42.1.0/24 via ... mtu 1320`. It tells the kernel: "for packets going to this destination, act as if the MTU is 1320 even though the interface MTU is higher." This is what TCP uses to compute MSS for a specific connection, and what PMTUD updates when it discovers the real path ceiling. Route MTU can be lower than interface MTU without changing the interface.

**Effective tunnel MTU.** The maximum payload the full overlay stack can carry without fragmenting or dropping. This is what you calculate from first principles: start with the physical NIC MTU, subtract each encapsulation layer's overhead. For this cluster: 1450 − 80 (WireGuard) − 50 (VXLAN) = **1320 bytes**.

The distinction matters because Cilium sets interface MTU and route MTU in different places, and the two don't always agree.

---

## Symptoms of an MTU problem

If you're here because something is broken, look for these:

- Cross-node TCP mostly works; cross-node ICMP or UDP silently dies above a specific size
- Same-node pod-to-pod traffic works fine; cross-node doesn't
- Small pings succeed; large pings fail (especially above ~1300 bytes payload)
- `node_netstat_Ip_FragFails` is non-zero and growing on node-exporter
- Hubble shows drops with reason related to packet size
- `just verify-mtu` fails on the ping or cilium_wg0 checks

---

## Background: how a packet travels between two pods on different nodes

**The physical layer.** Hetzner gives each node a private network interface (`enp7s0`) with **MTU 1450**. Hetzner's own SDN takes 50 bytes for its internal encapsulation before your packets hit the wire. You cannot change this.

**WireGuard.** Cilium runs WireGuard between every pair of nodes to encrypt all pod-to-pod traffic in transit. WireGuard wraps each packet in an outer UDP datagram. The overhead is exactly **80 bytes**, broken down as:

```
IPv6 outer header:       40 bytes   (Cilium uses IPv6 between nodes)
UDP header:               8 bytes
WireGuard type field:     4 bytes
WireGuard reserved:       4 bytes
WireGuard nonce:          8 bytes   (security-critical; prevents replay attacks)
Poly1305 auth tag:       16 bytes   (integrity check over the encrypted payload)
─────────────────────────────────
Total:                   80 bytes
```

Cilium creates a virtual interface `cilium_wg0` for this tunnel. Its MTU: `1450 − 80 = 1370`.

**VXLAN.** Cilium uses VXLAN to route pod traffic across nodes independently of Hetzner's routing table — necessary because Hetzner's network doesn't know about pod CIDRs, especially in multicluster mode. VXLAN wraps the pod's IP packet inside another UDP/IP packet. Overhead: **50 bytes**. The VXLAN packet then travels inside the WireGuard tunnel.

**The full path and budget:**

```
Pod sends a packet
  │
  ▼
lxc interface (veth pair, host side)
  │  Cilium eBPF intercepts here
  ▼
VXLAN encapsulation  (+50 bytes overhead)
  │
  ▼
cilium_wg0  (MTU 1370)
  │  WireGuard encrypts  (+80 bytes overhead, sent as outer UDP)
  ▼
enp7s0  (MTU 1450)
  │
  ▼
Hetzner private network → remote node → destination pod
```

Maximum IP packet size that fits through this full chain:

```
enp7s0 MTU:         1450
- WireGuard:         - 80
= cilium_wg0 MTU:   1370
- VXLAN:             - 50
= effective ceiling: 1320 bytes
```

**1320 bytes is the ceiling.** Any cross-node IP packet larger than 1320 bytes has a problem.

---

## The problem we found

Cilium sets the MTU of pod network interfaces (`eth0` inside a pod) to **1450** — matching the native device MTU. Not 1320. This is intentional: Cilium's design is to handle the overhead transparently via eBPF rather than reducing what pods see.

For TCP, this works well in practice. Cilium's eBPF clamps the TCP MSS (Maximum Segment Size) during the three-way handshake so TCP connections are told upfront to use segments that fit within the path. TCP is mostly protected in the normal Cilium-managed path and rarely generates a drop. (If traffic were to bypass Cilium's eBPF path or use unusual encapsulation, TCP could still be affected.)

For **UDP and ICMP**, there is no MSS negotiation. The application sends whatever size it wants. A pod sending a 1400-byte UDP datagram cross-node just sends it — the eBPF tries to encapsulate it through VXLAN + WireGuard, the result exceeds what `cilium_wg0` can carry, and the packet is dropped.

The default Cilium behavior for these oversized non-TCP packets was `packetization-layer-pmtud-mode: blackhole` — **silent drop with no feedback**. No error, no log, no ICMP response to the sender. For TCP this is tolerable. For UDP, data vanishes.

**We confirmed this with packet-size tests:**

```sh
# From a pod on node A to a pod on node B (different nodes):
ping -s 1290 -c 3 <remote-pod-ip>   # payload 1290 + 28 headers = 1318 bytes → passes
ping -s 1292 -c 3 <remote-pod-ip>   # payload 1292 + 28 headers = 1320 bytes → passes (right at ceiling)
ping -s 1295 -c 3 <remote-pod-ip>   # payload 1295 + 28 headers = 1323 bytes → 100% loss
```

Note: busybox `ping` doesn't support `-M do` (explicit DF bit). The drops we measured happen inside Cilium's eBPF datapath, not at the kernel IP layer, which is why the kernel's `FragFails` counter doesn't always capture them.

We also found pre-existing `node_netstat_Ip_FragFails` kernel counters of 246/243/12 across the three nodes, confirming this was silently dropping real cluster traffic before we looked.

---

## What we fixed

### 1. Changed `blackhole` to `always` for PMTUD

**What PMTUD is.** Path MTU Discovery is a mechanism where the network stack learns the real ceiling for a given path. When an oversized packet is dropped, the dropper sends back an ICMP "Fragmentation Needed" message (type 3, code 4) to the sender, saying "this path can only carry up to X bytes." The sender caches this per destination (Linux keeps the cache for 10 minutes) and sizes future packets correctly.

**What changed.** With `mode: always`, Cilium's eBPF generates that ICMP feedback instead of silently dropping. The sending pod receives the ICMP, updates its path MTU cache, and retransmits at the right size.

**The cost.** PMTUD is reactive — the *first* oversized packet to a new destination still drops before the feedback arrives. After that, the cache is warm for 10 minutes. For a cluster with a handful of backend pod IPs, this means a one-time probe per IP at startup, then it's done. For TCP, this never fires at all — MSS clamping prevents oversized segments from being generated in the first place.

**Why ICMP feedback is reliable here.** In normal internet PMTUD, the "Fragmentation Needed" ICMP has to travel back across the network to the sender, and firewalls sometimes block ICMP, causing "black hole" paths. Here, the ICMP is generated by Cilium's eBPF *on the same node as the sending pod* and delivered locally. It never crosses a firewall.

```yaml
# kubernetes/base/infra/cilium/values.yaml
# Key confirmed from cilium/cilium Helm chart v1.19.4 values.yaml: .Values.pmtuDiscovery
pmtuDiscovery:
  enabled: true
  packetizationLayerPMTUDMode: "always"
```

### 2. WireGuard persistent keepalive: 25s

**The problem.** WireGuard peers don't maintain a persistent connection in the way TCP does. After a period with no traffic between two nodes, the WireGuard peer handshake state can expire. When the next packet arrives, WireGuard needs to re-establish the cryptographic handshake with the peer, which takes 300ms–2s. During that window, the first few packets may be lost or delayed.

On a cluster that's mostly idle at night, this means the first cross-node request after a quiet period could stall. Not catastrophic, but visible.

**The fix.** `persistentKeepalive: 25s` sends a small heartbeat to each WireGuard peer every 25 seconds, preventing the handshake state from expiring. 25 seconds is the standard recommendation (below most NAT/stateful firewall timeout thresholds, even though Hetzner's private network is not NAT'd — it's still good practice).

Encryption is unchanged — WireGuard is still encrypting everything.

```yaml
encryption:
  wireguard:
    persistentKeepalive: 25s
```

### 3. eBPF masquerade

When pods send traffic to the internet, their source IP is translated to the node's public IP (SNAT / masquerade). Previously this happened via an iptables NAT rule. Since this cluster uses `kubeProxyReplacement: true` — meaning Cilium's eBPF has fully replaced kube-proxy and iptables for service routing — having iptables still involved for masquerade was the one remaining legacy piece.

`bpf.masquerade: true` moves SNAT into the eBPF datapath. No iptables in the data path at all.

```yaml
bpf:
  masquerade: true
```

### 4. Prometheus metrics and Hubble metrics

Cilium was running a metrics endpoint but Prometheus had no ServiceMonitor to discover it. We added `prometheus.serviceMonitor.enabled: true` and `operator.prometheus.serviceMonitor.enabled: true`, plus five Hubble metric families:

- **`drop`** — `hubble_drop_total` labelled by reason and direction. The most important one. This surfaces silent eBPF-level drops before they become user-visible.
- **`tcp`** — TCP connection state machine counters.
- **`flow:sourceContext=namespace;destinationContext=namespace`** — cross-namespace traffic matrix. Namespace-level (not pod-level) to keep Prometheus label cardinality manageable.
- **`icmp`** — ICMP stats, including "Fragmentation Needed" responses if PMTUD fires.
- **`dns:query;ignoreAAAA`** — DNS query counts per name, minus AAAA noise.

---

## Things we tried that didn't work, and why

### Setting `MTU: 1320` in Cilium Helm values

The goal was to set pod interface MTU to 1320, so pods never generate oversized packets in the first place — proactive, not reactive.

The problem: Cilium's `MTU` Helm value is the **physical device MTU**, not a direct pod interface setting. Cilium derives other values from it, including `cilium_wg0 = MTU − WireGuard_overhead`. Setting `MTU: 1320`:

- Pod eth0 → 1320 ✓
- `cilium_wg0` → `1320 − 80 = 1240` ✗

A pod sending a 1320-byte packet generates a `1320 + 50 (VXLAN) = 1370`-byte packet destined for `cilium_wg0`. But `cilium_wg0` MTU is only 1240. `1370 > 1240`. The VXLAN traffic can't fit through the WireGuard tunnel, and everything breaks.

In this deployment mode, the single `MTU` value controls both the pod-facing MTU and the derived WireGuard tunnel MTU through the same formula, so lowering it to 1320 makes the WireGuard tunnel too small for VXLAN-encapsulated packets. There is no `MTU` setting that fixes pod MTU without breaking something else.

### `cni.enableRouteMTUForCNIChaining`

This option forces Cilium to set the route MTU inside pod network namespaces (`ip route replace default ... mtu 1320`). That would fix things at the route MTU level — pods would hit the ceiling at the socket layer rather than needing PMTUD. On paper, this is the right fix.

In practice: the option only activates when **CNI chaining** is in use — i.e., another CNI (like AWS VPC CNI) creates the veth pair and Cilium attaches as a secondary plugin. We run Cilium as the sole CNI with no chaining. This flag is a no-op in our setup, confirmed in [Cilium PR #33190](https://github.com/cilium/cilium/pull/33190) (merged June 2024).

### Why the ideal fix doesn't exist in 1.19.x (observed behavior and upstream status)

Cilium *does* install correct route MTU on the **host-side** cross-node routes. We verified this in our cluster:

```sh
# Inside a Cilium agent pod on hetzner-k3s-cp-1:
$ ip route show | grep mtu
10.42.1.0/24 via 10.42.0.148 dev cilium_host proto kernel src 10.42.0.148 mtu 1320
10.42.2.0/24 via 10.42.0.148 dev cilium_host proto kernel src 10.42.0.148 mtu 1320
```

But inside an ordinary pod's network namespace, we observed no route MTU hint:

```sh
# Inside a regular pod on hetzner-k3s-cp-1:
$ ip route show
default via 10.42.0.148 dev eth0
10.42.0.148 dev eth0 scope link

$ ip link show eth0
158: eth0@if159: <BROADCAST,MULTICAST,UP,LOWER_UP,M-DOWN> mtu 1450
```

No `mtu` on the default route. The pod's kernel doesn't proactively know about the 1320 ceiling. It has to learn through PMTUD.

This is consistent with [Cilium issue #37919](https://github.com/cilium/cilium/issues/37919) (verified open via search, most recently in May 2026; labeled help-wanted). The issue documents that Cilium doesn't propagate the correct route MTU into pod network namespaces for VXLAN+WireGuard configurations. The fix — plumbing the right route MTU into pod netns at pod creation time — was unimplemented in 1.19.x.

**Bottom line.** `pmtuDiscovery.enabled: true` with `mode: always` is the correct and supported workaround. It's not a hack — it's the intended fallback when route MTU isn't set in pod netns.

---

## Monitoring coverage

Four alerts cover networking health. All metrics confirmed live in our cluster before being written into the PrometheusRule.

| Alert | Metric | What it catches |
|---|---|---|
| `KernelIPFragFails` | `node_netstat_Ip_FragFails` | Kernel-level drops of DF-set packets — the earliest signal of MTU misconfiguration |
| `HubbleDropsDetected` | `hubble_drop_total` | eBPF-level drops including policy violations and drops that bypass the kernel counter |
| `CiliumUnreachableNode` | `cilium_unreachable_nodes` | Node failing cilium-health probes — primary cause is WireGuard handshake failure |
| `CiliumUnreachableEndpoints` | `cilium_unreachable_health_endpoints` | Pod-level health check failures, distinct from node-level |

`KernelIPFragFails` is the most direct signal: non-zero means a packet with the DF bit set was too large to forward somewhere. Pre-fix, we had 246/243/12 across three nodes with no alert to catch it.

---

## Verifying after a Cilium config change

```sh
just verify-mtu
```

Six checks, what each one actually verifies:

1. **Pod `eth0` MTU == 1450** — confirms Cilium auto-detected `enp7s0` correctly and no accidental `MTU:` override snuck in
2. **Cross-node ping, 1280-byte payload** — `1280 + 28 = 1308`-byte packet; comfortable margin below ceiling, path is functional
3. **Cross-node ping, 1292-byte payload** — `1292 + 28 = 1320`-byte packet; exactly at the VXLAN+WireGuard ceiling, any regression shows here
4. **`cilium_wg0` MTU == 1370 on all nodes** — confirms WireGuard overhead is correctly subtracted from 1450; wrong value means MTU formula broke
5. **PMTUD active** — checks configmap for `enable-pmtu-discovery=true` and `packetization-layer-pmtud-mode=always`
6. **cloudflared `quic_client_mtu` ≥ 1300** — egress sanity check (pod→internet path, not pod→pod overlay). cloudflared subtracts its own protocol overhead from the pod's 1450 MTU: `1450 − 20 (IPv4) − 8 (UDP) − 17 (QUIC header) − 16 (AEAD tag) − 45 (Cloudflare tunnel framing) = 1344`. If this drops below 1300, the pod MTU is being clamped somewhere it shouldn't be.

Run this after `just argocd-bootstrap`, after any Cilium Helm values change, and after a full cluster rebuild.

---

## Quick reference: every number cold

```
enp7s0 (Hetzner private NIC):          1450  ← cannot change
WireGuard IPv6 outer breakdown:          -80  (40 IPv6 + 8 UDP + 4+4+8 WG fields + 16 Poly1305)
  └─ if IPv4 outer (not this cluster):  -60  (20 IPv4 + 8 UDP + 4+4+8 WG fields + 16 Poly1305)
cilium_wg0:                             1370  ← Cilium auto-calculates from enp7s0 MTU
VXLAN overhead:                          -50
Effective cross-node path ceiling:      1320  ← max IP packet size for cross-node pod traffic
Max ICMP payload before drop:           1292  ← 1292 + 8 (ICMP) + 20 (IP) = 1320
TCP MSS (eBPF-clamped):               ≤1280  ← TCP never reaches the ceiling
cloudflared QUIC MTU (egress only):    ~1344  ← unrelated to overlay; reflects pod→internet path
```
