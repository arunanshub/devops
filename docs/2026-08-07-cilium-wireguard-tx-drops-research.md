# Cilium WireGuard transmit-drop investigation

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

- Which remote peer accounts for each local staged-queue discard.
- Whether each discard is queue overflow or a staged-packet purge.
- What temporarily prevents immediate encryption despite successful peer
  handshakes and stable CiliumNode keys.
- What changed the cross-node packet volume at the same time as the Cilium
  rollout.
- Whether the installed Ubuntu kernel has the CVE fix despite the current
  Canonical package-family status.
