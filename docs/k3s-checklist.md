# K3s on Hetzner — setup checklist

## Operating philosophy

Two principles govern every decision in this setup:

**Production-grade from hour one.** This does not mean running 10 nodes. It means having the *properties* of production systems at any scale: every change is traceable in git, no snowflakes exist on any node, failures are observable before you notice them manually, and persistent data is never stored on ephemeral compute.

**Boring by design.** The system should be more likely to fix itself than to require you to fix it. Every manual intervention is a failure of system design. Concretely:

- **Replace, never repair.** A broken node gets `tofu destroy` + `tofu apply`, not an SSH session. This is only possible if nodes are truly stateless — all persistent data lives in Hetzner volumes, never on local disk.
- **One path to deploy, always.** Nothing is ever `kubectl apply`-ed directly. Everything goes through ArgoCD. Every deployment is in git, auditable, and reversible.
- **Automate the response, not just the detection.** An alert that requires you to act at 3am is a design failure. The system should self-heal; you should only receive a morning summary.
- **Blast radius is always small.** Resource requests and limits on every workload. Namespace isolation between apps. One bad actor cannot starve the cluster.

---

## Code organisation

**One file per concern** inside a single root module. OpenTofu treats all `.tofu` files in a directory as one flat namespace — files are purely for human readability.

```
infra/
├── main.tf            ← terraform block (encryption, required_providers) + provider config only
├── variables.tf       ← all variable declarations
├── outputs.tf         ← all outputs
├── servers.tf         ← hcloud_server, hcloud_ssh_key, terraform_data for kubeconfig
├── network.tf         ← hcloud_network, hcloud_subnet
├── firewall.tf        ← hcloud_firewall, hcloud_firewall_attachment
├── lb.tf              ← hcloud_load_balancer, targets, network attachment (API server LB)
├── locals.tf          ← derived node sets, k3s config generation, TLS SANs
├── secrets.yaml       ← SOPS-encrypted values
└── justfile           ← sops exec-env wrappers for tofu commands

kubernetes/
├── bootstrap/
│   ├── helmfile.yaml             ← ArgoCD + Cilium + CCM, run once
│   ├── helmfile.lock
│   ├── gateway-api-crds/         ← kustomization for bootstrap-time CRD install
│   ├── secrets/
│   │   ├── helmfile.secrets.yaml         ← SOPS-encrypted (ArgoCD admin bcrypt hash)
│   │   ├── argocd-repo-ssh.sops.yaml     ← SOPS-encrypted SSH deploy key
│   │   ├── hcloud-ccm-secret.sops.yaml   ← SOPS-encrypted hcloud token + network (bootstrap)
│   │   └── sealed-secrets-master-key.sops.yaml ← offline backup of Sealed Secrets key
│   └── values/
│       ├── argocd.yaml
│       ├── bootstrap.yaml.gotmpl ← injects ARGOCD_ADMIN_PASSWORD_HASH via requiredEnv
│       ├── ccm.yaml
│       └── cilium.yaml.gotmpl    ← injects K8S_API_ENDPOINT via requiredEnv
├── base/
│   ├── kustomization.yaml        ← references infra/ and monitoring/
│   ├── infra/
│   │   ├── kustomization.yaml
│   │   ├── appproject.yaml           ← AppProject/infra (sync wave -2)
│   │   ├── argocd/
│   │   │   ├── application.yaml      ← makes ArgoCD self-managing
│   │   │   └── values.yaml
│   │   ├── sealed-secrets/
│   │   │   ├── application.yaml
│   │   │   └── values.yaml
│   │   ├── system-upgrade-controller/
│   │   │   ├── application.yaml
│   │   │   ├── plans-application.yaml
│   │   │   └── plans/k3s-server.yaml
│   │   ├── kured/
│   │   │   ├── application.yaml
│   │   │   └── values.yaml
│   │   ├── gateway-api-crds/         ← ArgoCD steady-state ownership of CRDs
│   │   │   ├── application.yaml
│   │   │   └── kustomization.yaml
│   │   ├── hcloud-secret/            ← SealedSecret (wave 1)
│   │   │   ├── application.yaml
│   │   │   ├── kustomization.yaml
│   │   │   └── sealed-secret.yaml
│   │   ├── hcloud-ccm/               ← wave 2
│   │   │   ├── application.yaml
│   │   │   └── values.yaml
│   │   ├── hcloud-csi/               ← wave 3
│   │   │   ├── application.yaml
│   │   │   └── values.yaml
│   │   ├── cilium/                   ← wave 1, selfHeal, ServerSideApply
│   │   │   ├── application.yaml
│   │   │   └── values.yaml
│   │   ├── cert-manager/
│   │   │   ├── application.yaml
│   │   │   └── values.yaml
│   │   └── vpa/                      ← Fairwinds VPA chart (wave 1)
│   │       ├── application.yaml
│   │       └── values.yaml
│   └── monitoring/
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       ├── appproject.yaml
│       ├── kube-prometheus-stack-secrets/   ← wave 0
│       │   ├── application.yaml
│       │   ├── kustomization.yaml
│       │   ├── alertmanager-smtp.sealedsecret.yaml
│       │   └── grafana-admin.sealedsecret.yaml
│       └── kube-prometheus-stack/           ← wave 1
│           ├── application.yaml
│           └── values.yaml
├── components/
│   ├── argocd-app-controller-vpa/    ← kustomize component; included by overlays/prod
│   │   ├── application.yaml
│   │   ├── kustomization.yaml        ← kind: Component
│   │   └── resources/
│   │       ├── kustomization.yaml
│   │       ├── pdb.yaml
│   │       └── vpa.yaml
│   └── cainjector-vpa/               ← kustomize component; included by overlays/prod
│       ├── application.yaml
│       ├── kustomization.yaml        ← kind: Component
│       └── resources/
│           ├── kustomization.yaml
│           ├── pdb.yaml
│           └── vpa.yaml
├── overlays/
│   └── prod/kustomization.yaml   ← references ../../base + components; canonical ArgoCD entry point
├── kustomization.yaml            ← safety redirect → overlays/prod
├── root-application.yaml         ← applied once via just; tracks overlays/prod
└── sealed-secrets-cert.pem       ← public cert for sealing secrets locally (committed)
```

Key rules:
- `bootstrap/` is a one-time tool. Its only job was to get ArgoCD running. Never use it to deploy new apps.
- `base/infra/` is the living GitOps state of the cluster. Everything goes here, forever.
- `components/` holds kustomize components (`kind: Component`) for cross-cutting concerns that don't belong to a single AppProject — e.g. VPA objects targeting infra workloads. Included via `overlays/prod/kustomization.yaml`. Not rendered unless explicitly included by an overlay.
- Secrets in git are always `SealedSecret` resources or SOPS-encrypted files — never plain `Secret` manifests.
- Root app (`root-application.yaml`) tracks `kubernetes/overlays/prod` via kustomize and owns all Application/AppProject manifests. It is never managed by ArgoCD itself.
- App-of-Apps pattern (not ApplicationSet). The root app renders kustomize output; each child app manages its own sync loop independently.
- AppProject sync wave is `-2` — ensures the project exists before any Application in wave `-1` or higher tries to reference it.
- SUC Plans are a separate Application (wave `2`) from the controller itself (wave `1`), so the CRD is guaranteed to exist before the Plan CR is applied.
- CCM (wave 2) must sync before CSI (wave 3) — CSI requires ProviderID on the node, which CCM sets.
- `cert-manager-issuers` Application (wave 4) is separate from the `cert-manager` Application (wave 1) — `ClusterIssuer` CRD doesn't exist until cert-manager finishes installing.
- Any `Gateway` resource creates a Service of type `LoadBalancer`; hcloud CCM provisions a real paid Hetzner LB. Do not create `Gateway` resources without intending to pay for one. (Traefik owns the GatewayClass; Cilium Gateway API is disabled.)
- `kubernetes/kustomization.yaml` is a safety redirect to `overlays/prod` — prevents ArgoCD plain-directory mode from applying `root-application.yaml` as a raw resource and triggering a self-prune cascade.

**On modules and Terragrunt:** the flat single-module layout is correct through Phase 6. Two natural upgrade paths: (1) **child modules** for stamping identical resource groups; (2) **Terragrunt layers** for isolated state per concern. Neither is needed until the pain of not having them is felt.

---

## Phase 0 — local prerequisites ✅

- [x] OpenTofu, hcloud CLI, kubectl, sops, age, just, helmfile installed via devbox
  - `devbox.json` captures these — no manual reinstall needed on new machines
- [x] Age key generated at `~/.config/sops/age/keys.txt` and backed up
  - Losing this key = losing access to all encrypted secrets forever
- [x] SOPS set up with `.sops.yaml` pointing to your age public key
- [x] Hetzner account ready, API token generated (read+write, lives in `secrets.yaml` only)
- [x] SSH key uploaded to Hetzner console

---

## Phase 1 — single node cluster (CP + worker on same machine) ✅

- [x] Project structure created (`infra/`, `justfile`, `.gitignore`)
  - `.gitignore` must include: `*.tfstate`, `*.tfstate.backup`, `kubeconfig.yaml`, `.ssh_known_hosts`
- [x] OpenTofu state encryption enabled via `pbkdf2` + `aes_gcm` in `.tofu` block
- [x] `hcloud_server` provisioned with cloud-init installing k3s
  - Flags: `--cluster-init` (etcd, not sqlite), `--disable traefik`, `--disable servicelb`
  - `INSTALL_K3S_VERSION` must be pinned explicitly — never install latest implicitly
  - **GitHub is IPv4-only** — the k3s install script downloads its binary from GitHub releases, which fails on IPv6-only nodes. IPv4 is required at bootstrap time.
- [x] kubeconfig retrieved automatically via `terraform_data` + `local-exec` (no manual SSH)
  - SSH uses `StrictHostKeyChecking=accept-new` and a per-module `.ssh_known_hosts` file
  - IPv6 address patched into kubeconfig for kubectl traffic
- [x] `kubectl get nodes` + `kubectl get pods -A` verified working
- [x] IPv4 enabled for bootstrap; kubectl traffic confirmed working over IPv6
  - Use Docker Hub only — `ghcr.io` has no IPv6 support
- [x] `just` targets wrapping `sops exec-env` + `tofu` commands

---

## Phase 2 — hardening ✅

- [x] `hcloud_firewall` resource added
  - Allow inbound: SSH from your IP only, port 6443 (k3s API) from your IP only on CP nodes
  - Port 6443 lives in a separate `control_plane_api` firewall so workers never receive the rule
  - Block all other inbound. Outbound: unrestricted.
- [x] Firewall attached to server via `hcloud_firewall_attachment`
- [x] Deletion and rebuild protection: `prevent_destroy = true` in `lifecycle` block
  - `delete_protection` and `rebuild_protection` intentionally left `false` in resource — friction is at the Tofu lifecycle layer, not the API layer
- [x] Inter-node traffic encryption via Cilium WireGuard (handled in Phase 5)
- [x] Unattended OS security updates via Ansible `baseline` role
  - `unattended-upgrades` configured with `Automatic-Reboot: false` — kured handles reboots
  - Ansible inventory driven by a Go binary reading Tofu outputs directly; schema drift fails loudly at unmarshal time
- [x] k3s auto-upgrade via `system-upgrade-controller`
  - SUC v0.19.2 deployed via ArgoCD, pointing at upstream repo at pinned tag
  - Plan targets `https://update.k3s.io/v1-release/channels/stable`
  - Plans are a separate ArgoCD Application (wave 2) to guarantee CRD exists before Plan CR is applied
- [x] Automatic node reboots via `kured`
  - kured 1.21.0 (chart 5.11.0) deployed via ArgoCD into `kube-system`
  - `useRebootSentinelHostPath: true` (default) mounts host `/var/run` at `/sentinel` inside container
  - Do NOT set `rebootSentinel: /var/run/reboot-required` — that path is inside the container, not the hostPath mount point (`/sentinel/reboot-required`)
  - Maintenance window: 02:00–04:00 IST; timezone `Asia/Kolkata`
  - `metrics.create: true` with `release: kube-prometheus-stack` label set from the start

---

## Phase 3 — observability ✅

- [x] `kube-prometheus-stack` v84.5.0 deployed via ArgoCD (Prometheus + Grafana + Alertmanager in one chart)
  - AppProject `monitoring` with separate namespace; `monitoring-secrets` app (wave 0) deploys SealedSecrets before the stack (wave 1)
  - `serviceMonitorSelectorNilUsesHelmValues: false` — picks up all ServiceMonitors in the cluster regardless of Helm labels
  - k3s-incompatible components disabled: `kubeEtcd`, `kubeControllerManager`, `kubeScheduler`, `kubeProxy` and their corresponding default rules
- [x] Alertmanager configured with SMTP via Resend
  - SMTP password stored as SealedSecret, mounted into Alertmanager pod via `alertmanagerSpec.secrets`
  - Password read from file (`smtp_auth_password_file`) — never in plaintext in values
  - Watchdog alert silenced via null receiver; all other alerts route to email
- [x] Grafana admin credentials stored as SealedSecret (`grafana-admin`)
  - `existingSecret` + `userKey`/`passwordKey` pattern — no plaintext credentials in values
- [x] Grafana dashboards verified (cluster CPU, memory, pod status at a glance)

---

## Phase 4 — private networking + storage ✅

- [x] `hcloud_network` + `hcloud_subnet` created
  - Network `10.0.0.0/16`, subnet `10.0.0.0/24` (`eu-central`)
  - Must exist before adding a second node — do not defer
- [x] k3s configured with `--node-ip`, `--disable-cloud-controller`, `--cloud-provider=external`, `--tls-san`
  - Set at provision time in `init.sh.tpl` via `config.yaml`; TLS SANs include LB public IPv4, LB private IP, node private IP, and node public IPv6 (patched in at first boot)
- [x] Hetzner Cloud Controller Manager (CCM) v1.30.1 deployed via ArgoCD (wave 2)
  - hcloud secret (`token` + `network` keys) deployed as SealedSecret in `kube-system` (wave 1, before CCM)
  - `networking.enabled: true` with `clusterCIDR: 10.42.0.0/16` (k3s default pod CIDR)
  - PodMonitor enabled with `release: kube-prometheus-stack` label
  - `replicaCount: 2`, `strategy: maxSurge: 0, maxUnavailable: 1` — required for hostNetwork rolling updates
  - `podAntiAffinity` (required, hostname topology) ensures one CCM pod per node
- [x] Hetzner CSI driver v2.5.1 deployed via ArgoCD (wave 3)
  - StorageClass `hcloud-volumes` created; `defaultStorageClass: false` to avoid conflict with k3s's `local-path` default
  - `volumeBindingMode: WaitForFirstConsumer` — volume provisioned in correct datacenter after pod scheduling
  - `allowVolumeExpansion: true`
  - ServiceMonitor enabled with `release: kube-prometheus-stack` label
  - Always specify `storageClassName: hcloud-volumes` explicitly in PVC specs — never rely on default
- [x] Persistent storage for Prometheus, Grafana, Alertmanager on Hetzner Volumes
  - Prometheus: 10Gi volume, `retentionSize: 9GiB`, `retention: 14d`
  - Grafana: 10Gi volume; Alertmanager: 10Gi volume
  - **Note:** Volumes are location-scoped to `hel1`. CSI + `WaitForFirstConsumer` handles placement automatically.
  - **Note:** Volumes are NOT managed by OpenTofu — dynamically provisioned. Orphaned on cluster rebuild. Velero (Phase 8) required for full DR.

---

## Phase 5 — ingress + TLS ✅ *(partial — Gateway wiring deferred)*

**Path A — Cilium + Gateway API** *(chosen)*

k3s install flags required (all set at provision time via `init.sh.tpl`):
```
--flannel-backend=none
--disable-kube-proxy
--disable-network-policy
--disable traefik
--disable servicelb
```

- [x] Nodes provisioned with Cilium-compatible k3s flags from day one; never ran Flannel
- [x] Gateway API CRDs (standard channel v1.5.1) installed before Cilium bootstrap
  - Bootstrap: helmfile synthetic release. Steady-state: `gateway-api-crds` ArgoCD Application (wave 0)
  - Traefik owns the GatewayClass; Cilium Gateway API is disabled. Bump CRDs against Traefik's Gateway API support matrix, not Cilium's.
- [x] Cilium v1.19.4 (chart 1.19.4) deployed via helmfile bootstrap, adopted by ArgoCD
  - `kubeProxyReplacement: true`, `routingMode: tunnel` (VXLAN), WireGuard node encryption enabled
  - `hubble.tls.auto.method: cronJob` — deterministic cert renders, no ArgoCD OutOfSync churn
  - Hubble Relay + UI enabled; `cgroup.autoMount.enabled: false`
  - `selfHeal: true`; `ServerSideApply=true` for helmfile adoption
- [x] `cert-manager` v1.20.2 (chart v1.20.2) deployed via ArgoCD (wave 1)
  - Gateway API support enabled via file-based `ControllerConfiguration` (`enableGatewayAPI: true`)
  - CRDs installed and managed by Helm (`crds.enabled: true`)
- [x] `cert-manager-issuers` Application deployed at wave 4
  - `self-signed` ClusterIssuer deployed; cert issuance smoke-tested
- [ ] Domain acquired → add `letsencrypt-staging` + `letsencrypt-prod` ClusterIssuers
- [x] `Gateway` + `HTTPRoute` resources wired up for real workloads via Traefik + cloudflared
  - Traefik serves as GatewayClass; cloudflared terminates external ingress (no Hetzner LB provisioned for public traffic)

---

## Phase 6 — multi-node scale-out ✅ *(Autoscaler and Terragrunt deliberately deferred)*

- [x] `hcloud_server` resources use `for_each` over `var.nodes` map — topology is declarative
  - Node topology: 3× cx33 `cp_worker` nodes in `hel1` at `10.0.0.2–.4`
  - CP count validation in `variables.tf` enforces odd count at plan time
- [x] Nodes join cluster via shared `k3s_token` (SOPS-encrypted); join URL points at private LB
- [x] Three control plane nodes running embedded etcd (`--cluster-init` on bootstrap node only)
- [x] API server load balancer provisioned via `lb.tf`
  - `hcloud_load_balancer` (lb11) at `10.0.0.100` (private) in `hel1`
  - TCP passthrough on 6443, health check on TCP:6443
  - All CP nodes added as targets with `use_private_ip = true`
  - Cluster components use private LB IP; external kubectl uses bootstrap node IPv6 (firewall-restricted to home)
- [x] `is_cluster_initialized = true` in `terraform.tfvars` — `cluster-init` flag permanently absent from all node configs, any CP node can be safely replaced without split-brain
- [ ] Cluster Autoscaler — deliberately deferred; not needed at current scale
- [ ] Terragrunt — deliberately deferred; flat module is correct until multi-layer pain is felt

---

## Phase 7 — GitOps ✅

- [x] ArgoCD v3.3.9 (helm chart 9.5.11) bootstrapped via helmfile (`kubernetes/bootstrap/`)
  - `server.insecure: true` — TLS termination handled by Traefik + cloudflared at the edge
- [x] ArgoCD self-managing
  - `ServerSideApply=true`; no auto-sync, no auto-prune on self-managing app
- [x] Sealed Secrets v2.18.5 deployed as first ArgoCD Application
  - `fullnameOverride: sealed-secrets-controller` so `kubeseal` CLI works without extra flags
  - Master key backed up offline (SOPS-encrypted). Losing it = all sealed secrets permanently unrecoverable.
- [x] `sealed-secrets-cert.pem` fetched and committed to repo
- [x] GitHub deploy key sealed and applied; ArgoCD accesses private repo via SSH
- [x] Root Application tracks `kubernetes/overlays/prod` via kustomize
  - Applied once via `just argocd-root-bootstrap`; never managed by ArgoCD itself
- [x] AppProject/infra at sync wave `-2`; destinations include `argocd`, `kube-system`, `system-upgrade`, `cilium-secrets`, `cert-manager`
- [x] system-upgrade-controller v0.19.2 deployed; Plans in separate Application at wave `2`
- [x] kured 1.21.0 deployed; first OS reboot handled cleanly

---

## Phase 8 — backups *(deliberately deferred)*

Backups are deferred until the declarative + immutable workflow is fully internalised. The cluster is treated as a toy until at least one successful backup-restore drill is completed.

**etcd snapshots** — k3s ships snapshots to Hetzner Object Storage (S3-compatible). Single flag change. Covers cluster state only, not persistent volume data.

**Velero** — backs up both Kubernetes manifests and persistent volume data via CSI snapshots. The production-grade answer for full cluster backup and disaster recovery.

A restore drill must be performed when both are in place — an untested backup is not a backup.

- [ ] k3s etcd snapshots configured to ship to Hetzner Object Storage
- [ ] Hetzner Object Storage bucket created, access credentials scoped to backup use only
- [ ] Velero deployed with Hetzner CSI snapshot support (CSI data movement mode → Backblaze B2)
- [ ] Restore drill completed and documented
- [ ] ArgoCD auto-sync disabled before any restore to avoid conflict

---

## Phase 9 — workload resilience *(in progress)*

Autoscaling and disruption budget patterns for cluster infrastructure and future application workloads.

**Decision framework:**
- Traffic/requests drive resource usage → HPA (stateless, horizontally scalable workloads)
- External event queue drives scaling → KEDA (queue consumers, batch, scale-to-zero)
- Sizing unknown or variable but not traffic-driven → VPA recommendation mode first, then `InPlaceOrRecreate`
- VPA `Auto` is deprecated as of VPA 1.5/1.6 — use `InPlaceOrRecreate` instead
- VPA `InPlaceOrRecreate` + PDB is the correct pairing for singleton infra components

**Cluster notes:**
- None of the current infra workloads (CCM, Cilium, cert-manager, Sealed Secrets, SUC, kured) are HPA candidates — they are DaemonSets, leader-elected, or throughput-independent controllers
- HPA applies to future stateless application workloads only
- TSC (TopologySpreadConstraints) is the default for spreading application replicas; `podAntiAffinity` is reserved for cross-service co-location rules or when a chart only exposes `affinity:`
- `InPlacePodVerticalScaling` is GA in k3s v1.35.4 (cgroup v2 + containerd 2.x — both met on Ubuntu 24.04)

- [x] VPA deployed (Fairwinds chart `fairwinds-stable/vpa`) as ArgoCD Application under `infra` project
  - `base/infra/vpa/` — application.yaml + values.yaml
  - Fairwinds chosen over autoscaler community chart for better Helm ergonomics and more active maintenance
- [x] VPA + PDB for ArgoCD application-controller (`InPlaceOrRecreate` mode, `maxUnavailable: 1`)
  - Lives in `components/argocd-app-controller-vpa/` — kustomize component included by `overlays/prod`
  - Bounds: 50m–2 CPU / 128Mi–2Gi
  - `maxUnavailable: 1` is correct for a 1-replica StatefulSet — `minAvailable: 1` on a singleton permanently blocks node drains, kured reboots, and VPA Recreate fallback
- [x] VPA + PDB for Prometheus — enabled via chart values, **not** a raw VPA manifest
  - `prometheus.verticalPodAutoscaler.enabled: true`, `updateMode: InPlaceOrRecreate`, bounds: 100m–2 CPU / 512Mi–4Gi
  - `prometheus.podDisruptionBudget.enabled: true`, `minAvailable: 1`, `unhealthyPodEvictionPolicy: AlwaysAllow`
  - **Do not write a standalone VPA Application for Prometheus** — Prometheus Operator owns the StatefulSet and will fight raw VPA in the Recreate fallback path. Chart-native VPA avoids this conflict.
- [x] VPA + PDB for cert-manager cainjector — raw manifest is fine (not operator-managed)
  - Lives in `components/cainjector-vpa/` — kustomize component included by `overlays/prod`
  - Bounds: 10m–1 CPU / 64Mi–256Mi (`maxAllowed: memory: 256Mi` — original 128Mi ceiling is hit by the startup injection pass)
- [ ] VPA for ArgoCD repo-server and ArgoCD server — both Deployment targets, not operator-managed
  - repo-server is the priority: caches Helm renders and git objects in memory; measurably larger footprint than other ArgoCD components
  - ArgoCD chart has no native VPA support — follow the `components/` pattern
- [ ] After 2+ weeks of VPA data: review recommendations, update resource requests in values.yaml
  - Early signal (day 1): app-controller ~78m CPU / 728Mi RAM; Prometheus ~126m CPU / 1.45Gi RAM
  - When acting on data: bump app-controller `minAllowed.memory` to ~512Mi; revisit `maxAllowed` for app-controller and Prometheus as more Applications are added
  - `kubectl get vpa` short form shows first container alphabetically — for multi-container pods use `kubectl describe vpa` for per-container breakdown

---

## Hard-won lessons

### Bug 1 — SealedSecret CRD deadlock (the one that cost a night)

**Symptom:** Root app stuck in `SyncFailed`. Error: `The Kubernetes API could not find bitnami.com/SealedSecret`. Happens on every fresh sync or cluster rebuild.

**Why sync waves don't help:** Sync waves order manifest *application*, not child Application *completion*. ArgoCD does not wait for a child Application's Helm chart install to finish before moving to the next wave. The CRD installed by the child doesn't exist yet when the parent tries to apply resources that depend on it.

**Fix:** Raw `SealedSecret` manifests must never live in the root kustomization. Move them into their own dedicated Application with `selfHeal: true`. That Application retries independently until the CRD exists.

**Rule:** The root kustomization must only contain Application objects and CRD-free resources.

---

### Bug 2 — Application self-reference conflict ("two owners")

**Symptom:** ArgoCD reports a resource ownership conflict — an Application object is simultaneously owned by `root` and by itself.

**Why it happens:** Without a `kustomization.yaml`, ArgoCD uses directory source mode and picks up every YAML file in the path — including the `application.yaml` itself.

**Fix:** Every Application source path that points at your own repo must contain a `kustomization.yaml` that explicitly lists managed resources. The `application.yaml` sits in the directory but is invisible to the Application's sync.

---

### Bug 3 — CCM rolling update deadlock (hostNetwork port conflict)

**Symptom:** After increasing CCM replicas or changing the Deployment spec, a new pod stays `Pending` with `0/3 nodes are available: 3 node(s) didn't have free ports for the requested pod ports`.

**Why it happens:** CCM runs with `hostNetwork: true` (`networking.enabled: true`). With host networking, the metrics port 8233 is bound directly on the host. Default rolling update strategy (`maxSurge: 25%`) tries to start a new pod before terminating old ones. All nodes already have a CCM pod occupying port 8233 → new pod has nowhere to go → old pods won't terminate → deadlock.

**Fix:** Set `strategy: maxSurge: 0, maxUnavailable: 1`. This terminates one old pod first, freeing its node's port before the new pod starts. Safe for leader-elected workloads — the remaining replica acquires the lease immediately.

**Rule:** Any `hostNetwork: true` Deployment must use `maxSurge: 0` to avoid port conflict deadlocks during rolling updates.

---

### Bug 4 — VPA vs Prometheus Operator reconciliation conflict

**Symptom:** VPA recommendations are correct but Prometheus pod resources don't actually change. Or after VPA evicts the pod, resource requests revert to original values once the new pod starts.

**Why it happens:** Prometheus Operator owns the StatefulSet — its reconcile loop continuously syncs `prometheusSpec.resources` from the `Prometheus` CR into the StatefulSet pod template. When VPA patches the StatefulSet pod template (its Recreate eviction fallback path), the operator immediately overwrites it. VPA and the operator fight each other indefinitely.

**In-place path** (`InPlaceOrRecreate`): VPA resizes the running pod directly via the pod resize subresource — does not touch the StatefulSet. The operator doesn't watch individual pod resource specs. Works correctly.

**Recreate fallback**: VPA evicts the pod; the new pod is created from the StatefulSet spec, which the operator controls. VPA loses. Resources revert.

**Fix:** Use the kube-prometheus-stack chart's built-in `prometheus.verticalPodAutoscaler` and `prometheus.podDisruptionBudget` values instead of standalone VPA/PDB manifests. Do not write raw VPA objects targeting any operator-managed StatefulSet.

**Rule:** Raw VPA manifests are correct only for workloads where you directly own the Deployment or StatefulSet spec. For anything managed by an operator, use the chart's native VPA support if it exists.

---

### Bug 5 — ArgoCD Application deletion leaves orphaned resources

**Symptom:** ArgoCD Application is gone (deleted from git, pruned by root app, or `kubectl delete`-d), but the resources it was managing are still running in the cluster with no owner.

**Why it happens:** Deleting an ArgoCD Application object is non-cascading by default. ArgoCD only cascade-deletes managed resources if you explicitly request it — the Application object being gone does not trigger cleanup of the resources it was tracking.

**Fix (after the fact):** ArgoCD stamps `app.kubernetes.io/instance: <app-name>` on every resource it manages. That label survives Application deletion. Search for orphans:
```bash
kubectl api-resources --verbs=list --namespaced -o name \
  | xargs -I{} kubectl get {} --all-namespaces \
      -l app.kubernetes.io/instance=<deleted-app-name> \
      --ignore-not-found 2>/dev/null
```
The `ketall` plugin (`kubectl krew install get-all`) is cleaner: `kubectl get-all --selector app.kubernetes.io/instance=<app-name>`.

**Prevention:** Add the cascade finalizer to Application manifests where you always want resources to die with the Application:
```yaml
metadata:
  finalizers:
    - resources-finalizer.argocd.argoproj.io
```
Or use `argocd app delete <app> --cascade` before removing from git.

---

## Key constraints to remember

- **State files** (`*.tfstate`): gitignored always, even though encrypted. Never commit.
- **ghcr.io**: no IPv6 support. Use Docker Hub for all images.
- **GitHub releases**: IPv4-only. IPv4 must be enabled at bootstrap time.
- **etcd quorum**: control plane count must always be odd (1, 3, 5).
- **Private network**: set up before adding a second node, not after.
- **k3s version**: always pinned via `INSTALL_K3S_VERSION`. Never install latest implicitly.
- **No direct `kubectl apply`**: once ArgoCD is live, all deployments go through it. Exceptions: `just argocd-ssh-bootstrap`, `just argocd-root-bootstrap`, `just restore-sealed-secrets-key`.
- **Nodes are cattle, not pets**: wanting to SSH in to fix something is a signal to improve observability or automation.
- **Cilium vs Flannel**: mutually exclusive at install time. Cannot migrate without a full rebuild.
- **Sealed Secrets master key**: back it up offline immediately after first deploy. Losing it = losing all sealed secrets permanently.
- **SealedSecrets are cluster-scoped by default**: a secret sealed for one cluster cannot be decrypted by another.
- **ArgoCD self-management**: never set auto-prune on the self-managing Application. Always use `ServerSideApply=true`.
- **helmfile is bootstrap-only**: all subsequent deployments go through ArgoCD.
- **AppProject sync wave**: always set `-2` on AppProject so it lands before any Application that references it.
- **SUC RBAC**: `ServerSideApply=true` is required on the SUC Application. RBAC changes never trigger pod restarts — `kubectl rollout restart` required after the fact.
- **kured sentinel path**: correct path inside the container is `/sentinel/reboot-required` (hostPath `/var/run` mounted at `/sentinel`). Do not override `rebootSentinel` to `/var/run/reboot-required`.
- **ArgoCD Last Sync vs Sync Status**: Last Sync advances only when ArgoCD applies a diff. Values-only changes at the child app level leave the root app's Last Sync unchanged — this is correct.
- **Hetzner Volumes are location-scoped**: a volume in `hel1` can only attach to a server in `hel1`.
- **CSI volumes are not managed by OpenTofu**: orphaned on cluster rebuild. Velero (Phase 8) required for full DR.
- **StorageClass default**: `hcloud-volumes` intentionally not default. Always specify `storageClassName: hcloud-volumes` explicitly.
- **Gateway API creates real Hetzner LBs**: any `Gateway` resource → Service/LoadBalancer → paid Hetzner LB via hcloud CCM. Do not create without intending to pay. Traefik owns the GatewayClass; Cilium Gateway API is disabled.
- **cert-manager Gateway API support**: must be enabled via file-based `ControllerConfiguration` (`enableGatewayAPI: true`). Without it, `cert-manager.io/cluster-issuer` on Gateway resources is silently ignored.
- **cert-manager CRD-dependent resources**: `ClusterIssuer`, `Certificate`, etc. must live in a separate Application with `selfHeal: true`.
- **Hubble TLS certs**: `hubble.tls.auto.method: cronJob` — not `helm`. Helm's `genCA` is non-deterministic, causes perpetual OutOfSync with `selfHeal: true`.
- **Gateway API CRD version follows Traefik**: Cilium Gateway API is disabled; version coupling to Cilium no longer applies. Bump CRDs against Traefik's Gateway API support matrix. Keep bootstrap and ArgoCD steady-state versions in sync.
- **CCM hostNetwork rolling updates**: `strategy: maxSurge: 0, maxUnavailable: 1` is required. Default maxSurge causes port conflict deadlock.
- **`is_cluster_initialized`**: must be `true` in `terraform.tfvars` after initial bootstrap. Prevents `cluster-init` from appearing in any node's config, making every CP node safely replaceable.
- **HPA vs TSC vs podAntiAffinity**: TSC is the default for spreading your own replicas. podAntiAffinity for cross-service rules or when a chart only exposes `affinity:`. HPA only for stateless, traffic-driven, horizontally scalable workloads.
- **VPA `Auto` is deprecated**: use `InPlaceOrRecreate` mode (GA in VPA 1.6.0). Requires k8s ≥ 1.33 with `InPlacePodVerticalScaling` (GA in 1.35, enabled by default). Falls back to pod eviction if in-place resize fails; pair with PDB for singletons.
- **Singleton PDB pattern**: For 1-replica workloads use `maxUnavailable: 1`, not `minAvailable: 1`. `minAvailable: 1` on a singleton permanently blocks all voluntary evictions — node drains, kured reboots, and VPA Recreate fallback. `maxUnavailable: 1` permits eviction while still marking the pod as disruption-sensitive.
- **VPA and operator-managed workloads**: raw VPA manifests pointing at operator-owned StatefulSets only work reliably for in-place resizes. The Recreate fallback path is neutralized by operator reconciliation. Use chart-native VPA support (e.g. `prometheus.verticalPodAutoscaler`) for any workload managed by an operator.
- **ArgoCD Application deletion is non-cascading by default**: deleting an Application (via git prune or `kubectl delete`) leaves managed resources orphaned. To cascade: either `argocd app delete <app> --cascade` before removing from git, or add `finalizers: [resources-finalizer.argocd.argoproj.io]` to the Application manifest.
- **Finding orphaned ArgoCD resources**: ArgoCD stamps `app.kubernetes.io/instance: <app-name>` on every managed resource. After accidental orphaning, search with `kubectl api-resources --verbs=list -o name | xargs -I{} kubectl get {} --all-namespaces -l app.kubernetes.io/instance=<app-name> --ignore-not-found`. The `ketall` plugin (`kubectl krew install get-all`) is cleaner for this.
