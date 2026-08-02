# Memory Index — arunanshu-infrastructure SRE Guardian

- [User Profile](user-profile.md) — Arunanshu Biswas, senior-level personal infra operator, wants concrete findings not boilerplate
- [Cluster Architecture](cluster-architecture.md) — 3× cx33 cp_worker in hel1, Cilium VXLAN+WireGuard, 1320B MTU, cloudflared tunnel, hcloud-csi storage
- [Security Posture 2026-06](security-posture-2026-06.md) — Audit findings: policyAuditMode gap, no admission controller, missing cloudflared readOnlyRootFilesystem, velero empty securityContext, tfvars committed
- [cloudflared forced HTTP/2 (live 2026-08)](cloudflared-forced-http2-live-2026-08.md) — connector protocol forced http2 (not quic), re-enabled 2026-07-31 with no evidence doc, outlived its original Grafana-only experiment scope; flagged as ingress-latency candidate
