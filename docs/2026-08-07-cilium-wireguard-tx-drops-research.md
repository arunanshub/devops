# Cilium WireGuard transmit-drop investigation

## Root cause and fix (added 2026-08-08)

The investigation is closed. The cause is a workload placement change, not a
Cilium or kernel fault.

### What happens in the kernel

The Linux WireGuard driver stages every outgoing packet in a per-peer queue.
This happens on every send, also when a valid key exists. The queue holds 128
packets. The sender drains the queue immediately after it adds packets. Many
CPUs can add packets to the same peer queue at the same time. When more than
128 packets sit in the queue between an add and a drain, the driver removes
the oldest packets and counts each one in `tx_dropped`. A GSO send of 64 KB
becomes about 48 segments at the 1355-byte WireGuard MTU. Three concurrent
large sends to one peer can exceed the 128-packet limit. A key gap is not
required. Source: `wg_xmit()` in Linux v6.8
`drivers/net/wireguard/device.c` (verified 2026-08-08).

### Evidence from the 2026-08-07 capture

- Drops occur only in seconds with a traffic burst. The burst seconds carry
  1,411 to 6,885 packets. The mean is 273 packets per second.
- The burst seconds align to the 30-second wall clock (:29-:31 and :58-:60).
  This matches the vmagent scrape interval.
- Handshakes and key rotation happen at seconds :04-:07 of odd minutes, on a
  clean 120-second cycle. No kernel WireGuard event occurs near any drop
  burst. A key or handshake gap is therefore not the mechanism.

### What changed on 2026-08-03

- Commit `c616002` (#123) merged at 06:00 UTC. ArgoCD rolled out Cilium
  1.20.0, ArgoCD chart 10.2.2, and hcloud-csi 2.22.1 together.
- Before the rollout, the three ArgoCD components (application-controller,
  repo-server, redis) all ran on `cp-1`. Their gRPC traffic never left the
  node.
- The rollout restarted these pods. The scheduler spread them:
  controller on `cp-1`, repo-server on `cp-2`, redis on `cp-3`. The chart's
  default anti-affinity did not cause this. That preset only separates
  replicas of the same component, and each component has one replica. The
  spread was scheduler placement chance.
- The WireGuard transmit rate stepped up in the 06:00-06:30 UTC window on
  all three nodes. `cp-2` (repo-server) rose from ~100 to ~277 packets per
  second. The cloudflared scale-up at 14:36 UTC shows no step.
- Per-pod counters show no pod increased its own traffic. The new cross-node
  traffic is the same ArgoCD traffic that was node-local before.
- Hubble on `cp-2` shows controller-to-repo-server gRPC (port 8081) as the
  top cross-node flow.
- `cp-2` is the dominant dropper (0.2-0.6 packets per second). Its drop rate
  stepped up at the same time as its traffic.

### Why drops follow traffic volume

The repo-server sends large manifest responses to the controller on `cp-1`.
The scrape targets on `cp-2` send large responses to vmagent on `cp-3` every
30 seconds. Both flows now share the WireGuard peer queues on `cp-2`. The
added ArgoCD traffic pushed the concurrent burst size past the 128-packet
staged-queue limit. Before 2026-08-03, the same scrape bursts ran without
drops.

### The fix

Soft pod affinity now co-locates the repo-server and redis with the
application-controller. See `kubernetes/base/infra/argocd/values.yaml` and
the identical bootstrap copy. The rule is `preferred`, so scheduling never
blocks when the target node is full. Residual risk: if the controller moves
to another node, the other two pods stay behind until their next restart.

The `CiliumWireGuardTransmitDrops` alert is now ratio-based. The old rule
fired on any drop increase, so it stayed red under benign traffic growth.
The new rule fires when drops exceed 0.05% of WireGuard transmit packets
over 30 minutes. The healthy baseline is ~0.005-0.01%. This event ran at
~0.07-0.2%. Real degradation starts near 0.5%. The queue overflow itself is
normal kernel behavior under synchronized bursts, and the 128-packet limit
is a compile-time constant. The correct response to future organic growth
is to accept the ratio, not to chase the counter.

### Verification result (2026-08-07 ~20:26 UTC rollout)

The experiment confirmed the root cause.

- After the co-location rollout, the first 10-minute window showed zero
  drops on all three nodes. The scrape traffic still crossed nodes in that
  window (vmagent still ran on `cp-3`). This isolates the ArgoCD traffic as
  the cause.
- The second window showed 15 drops on `cp-2` in 10 minutes (0.025 packets
  per second). This is inside the pre-2026-08-03 baseline envelope.
- `cp-2` WireGuard transmit fell from ~277 to ~121 packets per second.
- The `CiliumWireGuardTransmitDrops` alert is deployed in its ratio form
  and is not active. Cilium health is 3/3. All nodes are Ready.

Caveat: kured rebooted `cp-3` at 20:37 UTC (OS patch window) and cut the
clean observation at ~11 minutes. The reboot moved vmagent onto `cp-2`,
next to vmsingle, by chance. Cross-node traffic is now lower than any
recent baseline, partly by that accident. vmagent placement is not pinned.
A future drain can move it off `cp-2` again. Expect the WireGuard transmit
rate to rise back toward the 2026-07-30 to 2026-08-03 profile when that
happens, with drops near baseline and no alert. That is normal drift, not
a regression. Do not add more affinity for it unless drops return.

### Burst source confirmed (2026-08-07 21:37 UTC)

A later check confirmed the burst source. The vmagent configuration sets no
`scrape_align_interval` and no `scrape_offset`. The VictoriaMetrics
documentation says that vmagent spreads scrapes at random. The measured
behaviour does not agree with that statement.

A 110-second sample of `cilium_wg0` transmit packets on `cp-2` shows the
traffic peaks at seconds :30, :01, :27, and :58 of each minute. A
75-second Hubble capture in the same window shows the top flow is remote
node traffic to vmagent. The scrape targets are therefore synchronized to
the 30-second wall clock.

This confirms the mechanism. The scrape bursts alone stayed below the
128-packet limit before 2026-08-03. The ArgoCD traffic added a second
large stream to the same peer queues. The sum crossed the limit.

### Confounder note

Cilium 1.20.0 final rolled out in the same commit and the same minute. The
evidence points at the traffic increase, not at Cilium: the traffic step is
real new volume on `cilium_vxlan`, `cilium_wg0`, and the physical NIC, and
the rc.1-to-final source diff contains no datapath change. The fix is the
discriminator. If drops return to the ~0.01 baseline after co-location, the
traffic explanation is confirmed. If drops persist, check
`gso_max_size`/`gso_max_segs` on the Cilium devices next
(`ip -d link show`). A larger GSO size would let one send exceed 128
segments without a concurrency race.

## Scope

This investigates the increase in `node_network_transmit_drop_total` after
2026-08-03. It uses the live metrics and state collected from the three-node
cluster, Cilium 1.20.0 documentation and source history, the Cilium issue
tracker, and Linux WireGuard source and advisories. No cluster configuration
was changed.

## Assessment

The counter is a real discard inside the Linux WireGuard device. It is not a
drop on the Hetzner network interface. In Linux 6.8, `cilium_wg0` increments
`tx_dropped` when a peer's pre-encryption staged queue exceeds 128 packets. The
driver keeps packets in that queue when the peer has no usable sending key,
then starts a handshake. It also counts staged packets as dropped if that queue
is purged.

The current rate is small but not normal background accounting. The measured
aggregate is about 0.06% of WireGuard transmit packets, with no physical-NIC
drops or errors, no WireGuard receive drops, and no material change in TCP
retransmission ratio. This supports low current user impact, not zero packet
loss.

The direct mechanism is a WireGuard staged-queue overflow or purge while a peer
cannot immediately encrypt queued packets. A bounded dynamic-debug capture did
not show a failed handshake, peer replacement, CiliumNode key change, or Cilium
agent error. It did show successful handshakes and keypair replacement while
the drop counter continued to increase. This rules out a persistent peer outage
and does not support a Cilium peer-reconfiguration event during the capture.
The event that temporarily makes the sending key unusable remains unknown.

There is no source evidence that Cilium 1.20.0 final introduced a WireGuard
regression relative to 1.20.0-rc.1. The rc.1-to-final comparison contains no
WireGuard, encryption-agent, tunnel, or MTU implementation change. The timing
still matters because the final-version rollout restarted all agents at about
the same time that cross-node packet volume roughly doubled, but timing alone
does not establish a Cilium regression.

## Confirmed evidence

| Evidence | Meaning |
| --- | --- |
| All transmit drops are on `cilium_wg0`; `eth0` and `enp7s0` have zero transmit/receive drops and errors over seven days | This is internal WireGuard loss, not physical-link loss. |
| `cilium_wg0` receive drops are zero | The observed dashboard series is not a receive-queue problem. |
| The daily WireGuard transmit packet count roughly doubled after 2026-08-03 | Higher packet rate makes any short unusable-key window lose more packets. |
| The Linux driver removes old packets when `staged_packet_queue` is over `MAX_STAGED_PACKETS` and increments `tx_dropped` | The counter identifies discarded inner packets awaiting encryption. |
| The same driver restages packets and initiates a handshake when no current valid sending key exists or the key is rejected | A key/session gap is the direct mechanism consistent with the counter. |
| `node_network_transmit_errs_total` is zero | This does not match the separate missing-allowed-IP path, which increments `tx_errors`. |
| All current Cilium peers have recent handshakes and Cilium health is 3/3 | There is no persistent peer outage now. This does not rule out short historical handshake gaps. |

## Live bounded capture

The approved capture ran on `hetzner-k3s-cp-2` from
`2026-08-07T18:03:34.505Z` through `2026-08-07T18:18:33.979Z`:

| Measurement | Result |
| --- | --- |
| Samples | 894 one-second samples over 899.5 seconds |
| WireGuard transmit packets | 243,416 |
| WireGuard transmit drops | 142, in nine short bursts |
| Capture-window drop ratio | 0.0583% |
| WireGuard transmit errors | 0 |
| Physical `enp7s0` drops | 0 on all nodes |
| CiliumNode changes | None; resource versions and WireGuard public keys stayed unchanged |
| Cilium agent WireGuard or peer log entries | None |
| Kernel handshake failures, retries, invalid packets, or missing endpoints | None |

The kernel log showed successful handshakes, keepalives, and normal keypair
replacement for both remote peers. The drop bursts did not consistently align
with those successful handshakes. The final encryption status still reported
WireGuard mode, two peers, and the same local public key.

The deployed warning fired on all three nodes after its five-minute hold.
This confirms a cluster-wide WireGuard-device condition rather than a fault
isolated to `hetzner-k3s-cp-2`. A 60-second follow-up smoke capture completed
cleanly, restored dynamic debug, removed its remote temporary directory, and
recorded no drops in that shorter interval.

The execution environment terminated the first long-running controller process
during finalization. The remote sampler continued and completed the full
15-minute counter capture, but dynamic debug required manual cleanup. The
diagnostic now gives the remote sampler an `EXIT` trap that disables debug and
writes final artifacts even if the controller exits. An independent check
confirmed that dynamic debug is disabled.

Linux source references:

- [`wg_xmit()` stages packets and increments `tx_dropped` when the queue exceeds 128 packets](https://github.com/torvalds/linux/blob/v6.8/drivers/net/wireguard/device.c#L137-L218)
- [`wg_packet_send_staged_packets()` restages packets and initiates a handshake when no usable sending key exists](https://github.com/torvalds/linux/blob/v6.8/drivers/net/wireguard/send.c#L342-L413)
- [WireGuard timing and queue limits: rekey 120 seconds, reject 180 seconds, staged queue 128 packets](https://github.com/torvalds/linux/blob/v6.8/drivers/net/wireguard/messages.h#L40-L53)

## Documentation and issue-board findings

Cilium documents a known WireGuard limitation: packets can be dropped while
the device is reconfigured after endpoint or node updates. The linked issue
shows that replacing a peer's allowed-IP list creates a short window with no
matching peer. However, that kernel path increments `tx_errors`, not
`tx_dropped`. It is relevant operational context, but it does not explain this
cluster's zero-error, non-zero-drop counters.

- [Cilium WireGuard validation, troubleshooting, and known issues](https://docs.cilium.io/en/stable/security/network/encryption-wireguard/)
- [Cilium issue #33159: WireGuard peer reconfiguration can interrupt traffic](https://github.com/cilium/cilium/issues/33159)

The Cilium issue board does not contain a report that matches sustained, low
`cilium_wg0` `tx_dropped` growth on 1.20.0. An open issue asks for WireGuard key
rotation coverage in CI, so this area does not have complete regression
coverage. A recent handshake-failure report is a total cross-node outage and
does not match this cluster's current healthy peers.

- [Cilium issue #37920: add WireGuard key-rotation CI coverage](https://github.com/cilium/cilium/issues/37920)
- [Cilium issue #47565: complete WireGuard handshake failure](https://github.com/cilium/cilium/issues/47565)
- [Cilium 1.20.0 release](https://github.com/cilium/cilium/releases/tag/v1.20.0)
- [Cilium 1.20.0-rc.1 to 1.20.0 source comparison](https://github.com/cilium/cilium/compare/v1.20.0-rc.1...v1.20.0)

## Separate kernel risk found during the audit

`CVE-2026-52945` is directly relevant to Cilium with WireGuard but is not a
good explanation for the current transmit-drop graph. The kernel advisory
describes a threaded-NAPI bug that can permanently stop decryption for one
peer under load. Its failing queue is the 1,024-packet receive queue; the
observed metric comes from the separate 128-packet transmit staged queue. The
advisory's symptom is a persistent per-peer outage, while all current peers in
this cluster exchange traffic and have recent handshakes.

As of 2026-08-07, Canonical marks the Ubuntu 24.04 `linux` package as
vulnerable. The live nodes run `6.8.0-136-generic`, but the read-only runtime
check returned `/sys/class/net/cilium_wg0/threaded = 0` on all three nodes.
The affected threaded-NAPI path is therefore disabled in this cluster. Track
the Ubuntu advisory, but this CVE is neither the cause of the transmit counter
nor an active runtime exposure with the current interface state.

- [Kernel.org CVE details and fix references via NVD](https://nvd.nist.gov/vuln/detail/CVE-2026-52945)
- [Canonical status for CVE-2026-52945](https://ubuntu.com/security/CVE-2026-52945)
- [Linux threaded-NAPI control documentation](https://git.zx2c4.com/wireguard-linux/tree/Documentation/networking/napi.rst)

## Safe next diagnostics

Completed in this change:

1. A dashboard now separates `cilium_wg0` drops, WireGuard drop percentage, and
   physical `enp7s0` drops.
2. A warning now detects sustained `cilium_wg0` transmit drops.
3. A guarded Ansible diagnostic samples the interface, CiliumNode state, Cilium
   encryption state, Cilium logs, and bounded WireGuard dynamic debug.

The next diagnostic needs review before implementation. A narrow kernel probe
at the two `tx_dropped` update paths should distinguish queue overflow in
`wg_xmit()` from a staged-packet purge and record the affected peer. Do not
change the queue size, restart Cilium, or roll back Cilium based on the current
evidence.

Do not roll back from 1.20.0 to the release candidate based on this evidence.
There is no matching code change, and a release candidate is the weaker
production baseline. Do not tune the WireGuard queue size: it would delay loss
without fixing the missing-key interval.

## Unknowns

Resolved on 2026-08-08 (see "Root cause and fix" above):

- ~~Whether each discard is queue overflow or a staged-packet purge.~~
  It is queue overflow in `wg_xmit()`. A purge needs a peer removal, and
  CiliumNode state stayed stable.
- ~~What temporarily prevents immediate encryption despite successful peer
  handshakes and stable CiliumNode keys.~~ Nothing does. The overflow does
  not need a key gap. Staging happens on every send, and concurrent bursts
  alone exceed the 128-packet limit.
- ~~What changed the cross-node packet volume at the same time as the Cilium
  rollout.~~ The ArgoCD 10.2.2 restart spread the controller, repo-server,
  and redis across three nodes. Their traffic was node-local before.

Still open, and not blocking:

- Which remote peer accounts for each local staged-queue discard. The
  per-peer split needs a kernel probe. It is not needed after the fix.
- Whether the installed Ubuntu kernel has the CVE fix despite the current
  Canonical package-family status.
