---
name: security-posture-2026-06
description: Security audit findings from June 2026 — known gaps, intentional design, and accepted risks
metadata:
  type: project
---

Security audit performed 2026-06-17. Key findings recorded for future sessions.

**Intentional, accepted design:**
- `policyAuditMode: true` in Cilium values (`kubernetes/base/infra/cilium/values.yaml:59`) — policies log instead of drop; explicitly noted as temporary until policies validated via Hubble. Only one real CiliumNetworkPolicy exists (cloudflared). This means all 17 other namespaces have no enforced network segmentation.
- `server.insecure: "true"` on ArgoCD (`kubernetes/base/infra/argocd/values.yaml:3`) — intentional; ArgoCD sits behind ClusterIP service, Traefik reverse proxy, and cloudflared tunnel. TLS termination is at Cloudflare edge.
- Headlamp uses `cluster-admin` ClusterRoleBinding (`headlamp-admin`) — this is the Helm chart default; Headlamp needs broad read access for its cluster explorer. Mitigated by CF Access OTP gate.
- Velero server has `cluster-admin` — required for full backup/restore of cluster resources. Mitigated by no public exposure.
- Kured runs privileged with hostPID — required to trigger node reboots via systemd. This is the standard kured operational model.
- etcd-snapshot-health CronJob runs as root — amazon/aws-cli Python runtime crashes under runAsUser:1000 (documented inline in cronjob.yaml).

**Real gaps found:**
- `infra/terraform.tfvars` is tracked in git — contains cloudflare_account_id, cloudflare_zone_id, owner_email, and node topology. Not API tokens (those are in SOPS-encrypted secrets.yaml), but account IDs and zone IDs are enumeration risk.
- Cloudflare Access wildcard `*.arunanshu.dev` gates all admin UIs via email OTP. `arunanshu.dev` and `www.arunanshu.dev` have bypass policy (intentional for public blog). The Access gate is the ONLY auth layer for headlamp, argocd, grafana, prometheus, hubble, traefik dashboards.
- cloudflared Deployment manifest (`kubernetes/components/cloudflared/resources/deployment.yaml`) is missing `readOnlyRootFilesystem: true` in securityContext — the live container has a writable root.
- velero Deployment has empty `securityContext: {}` — no `allowPrivilegeEscalation: false`, no `readOnlyRootFilesystem`, no dropped capabilities.
- No Kubernetes API server audit logging configured (no `--audit-log-path` in k3s config).
- No admission policy controller (Kyverno/OPA/Gatekeeper) — no enforcement of security baselines.
- `infra/velero/values.yaml:18` has Cloudflare R2 account ID hardcoded in the s3Url.

**Why:** These are noted for future remediation, not blocking issues for a single-operator personal homelab.
**How to apply:** When reviewing new workloads or changes, check if cloudflared's missing readOnlyRootFilesystem has been fixed. Track policyAuditMode as a recurring open item — once policies are validated via Hubble it should be flipped to false.
