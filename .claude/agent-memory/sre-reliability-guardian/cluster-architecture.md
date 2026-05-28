---
name: cluster-architecture
description: Cluster architecture snapshot — topology, network stack, storage, key decisions
metadata:
  type: project
---

## Cluster topology (as of 2026-05-28)

- 3× cx33 `cp_worker` nodes in `hel1`: cp-1 (10.0.0.2), cp-2 (10.0.0.3), cp-3 (10.0.0.4)
- All nodes dual-role (control-plane + worker) — no dedicated workers
- k3s v1.35.4+k3s1, embedded etcd, `is_cluster_initialized=true`
- API LB private IP: 10.0.0.100, lb11 type

## Network stack

- Cilium 1.19.4, VXLAN tunnel mode, WireGuard node encryption (`nodeEncryption: true`)
- MTU budget: 1450 (Hetzner NIC) − 80 (WireGuard) − 50 (VXLAN) = **1320 bytes** effective pod MTU
- `pmtuDiscovery.enabled: true`, `packetizationLayerPMTUDMode: always`
- Cilium replaces kube-proxy (`kubeProxyReplacement: true`) and CNI
- hccm 1.31.1 for LoadBalancer services and node labeling
- No public LoadBalancer for ingress — cloudflared tunnel → Traefik (ClusterIP) → Gateway API → HTTPRoutes
- WireGuard runs over IPv6 between nodes

## Storage

- hcloud-csi with two StorageClasses:
  - `hcloud-volumes` (unencrypted) — used by Prometheus only
  - `hcloud-volumes-encrypted` (LUKS via hcloud-csi) — used by Grafana, Alertmanager, Tempo
- Prometheus PVC deliberately unencrypted (metrics are not secrets)
- VolumeBindingMode: WaitForFirstConsumer on both classes
- All volumes location-scoped to hel1; orphaned on cluster rebuild

## Security model

- No NetworkPolicies (deny-by-default not implemented yet)
- SOPS (age key) for secrets in git; SealedSecrets for in-cluster
- Cloudflare Access (OTP email) for all *.arunanshu.dev
- ArgoCD server.insecure=true (TLS terminated by Traefik+cloudflared edge)
- No Kubernetes audit logging

## Known accepted deviations

- Prometheus uses `hcloud-volumes` (unencrypted) — acceptable-loss workload
- ArgoCD server.insecure=true — TLS is at the edge; intentional
- All 3 nodes in same location (hel1) — single availability zone; single-region failure risk accepted
- No node-level delete_protection/rebuild_protection (protection at Tofu lifecycle layer only)

**Why:** Noted in docs/k3s-checklist.md and runbook.md.
