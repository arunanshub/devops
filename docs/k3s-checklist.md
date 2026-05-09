# K3s on Hetzner — setup checklist

## Operating philosophy

Two principles govern every decision in this setup:

**Production-grade from hour one.** This does not mean running 10 nodes. It means having the _properties_ of production systems at any scale: every change is traceable in git, no snowflakes exist on any node, failures are observable before you notice them manually, and persistent data is never stored on ephemeral compute.

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
├── main.tofu          ← terraform block (encryption, required_providers) + provider config only
├── variables.tofu     ← all variable declarations
├── outputs.tofu       ← all outputs
├── servers.tofu       ← hcloud_server, hcloud_ssh_key, terraform_data for kubeconfig
├── network.tofu       ← hcloud_network, hcloud_subnet (added in Phase 4)
├── firewall.tofu      ← hcloud_firewall, hcloud_firewall_attachment
├── secrets.yaml       ← SOPS-encrypted values
└── justfile           ← sops exec-env wrappers for tofu commands

kubernetes/
├── bootstrap/
│   ├── helmfile.yaml             ← ArgoCD only, run once
│   ├── helmfile.lock
│   ├── secrets/
│   │   ├── helmfile.secrets.yaml ← SOPS-encrypted (ArgoCD admin bcrypt hash)
│   │   └── argocd-repo-ssh.sops.yaml ← SOPS-encrypted SSH deploy key (applied once via just)
│   └── values/
│       ├── values.yaml           ← non-secret values (server.insecure: true)
│       └── bootstrap.yaml.gotmpl ← injects ARGOCD_ADMIN_PASSWORD_HASH via requiredEnv
├── infra/
│   ├── kustomization.yaml
│   ├── appproject.yaml           ← AppProject/infra (sync wave -2)
│   ├── argocd/
│   │   ├── application.yaml      ← makes ArgoCD self-managing
│   │   └── values.yaml
│   ├── sealed-secrets/
│   │   ├── application.yaml
│   │   └── values.yaml
│   ├── system-upgrade-controller/
│   │   ├── application.yaml      ← deploys SUC from upstream repo at pinned tag
│   │   ├── plans-application.yaml← separate app for Plan CRs (wave 2, after CRD)
│   │   └── plans/
│   │       └── k3s-server.yaml   ← Plan targeting stable channel
│   ├── kured/
│   │   ├── application.yaml
│   │   └── values.yaml
│   ├── hcloud-secret/
│   │   ├── application.yaml      ← SealedSecret for hcloud token + network name (wave 1)
│   │   ├── kustomization.yaml
│   │   └── sealed-secret.yaml
│   ├── hcloud-ccm/
│   │   ├── application.yaml      ← Hetzner CCM (wave 2)
│   │   └── values.yaml
│   ├── hcloud-csi/
│   │   ├── application.yaml      ← Hetzner CSI driver (wave 3)
│   │   └── values.yaml
│   ├── cilium/
│   │   ├── application.yaml      ← Cilium CNI (wave 1, selfHeal)
│   │   └── values.yaml
│   └── cert-manager/
│       ├── application.yaml      ← cert-manager v1.19.4 (wave 1)
│       ├── values.yaml
│       ├── issuers-application.yaml ← ClusterIssuers (wave 4, after CRDs)
│       └── issuers/
│           ├── kustomization.yaml
│           └── self-signed.yaml  ← smoke-test issuer; ACME issuers added when domain lands
├── monitoring/
│   ├── kustomization.yaml
│   ├── namespace.yaml            ← monitoring namespace
│   ├── appproject.yaml           ← AppProject/monitoring (sync wave -2)
│   ├── sealedsecrets-application.yaml ← monitoring-secrets app (wave 0)
│   └── kube-prometheus-stack/
│       ├── application.yaml      ← kube-prometheus-stack (wave 1)
│       ├── values.yaml
│       └── secrets/
│           ├── grafana-admin.sealedsecret.yaml
│           └── alertmanager-smtp.sealedsecret.yaml
├── kustomization.yaml            ← root kustomization, references infra/ and monitoring/
├── root-application.yaml         ← applied once via just; never managed by ArgoCD itself
└── sealed-secrets-cert.pem       ← public cert for sealing secrets locally (committed)
```

Key rules:

- `bootstrap/` is a one-time tool. Its only job was to get ArgoCD running. Never use it to deploy new apps.
- `infra/` is the living GitOps state of the cluster. Everything goes here, forever.
- Secrets in git are always `SealedSecret` resources or SOPS-encrypted files — never plain `Secret` manifests.
- Root app (`root-application.yaml`) is applied once manually via `just argocd-root-bootstrap`. It tracks `kubernetes/` via kustomize and owns all Application/AppProject manifests. It is never managed by ArgoCD itself.
- App-of-Apps pattern used (not ApplicationSet). The root app renders kustomize output; each child app manages its own sync loop independently.
- AppProject sync wave is `-2` — ensures the project exists before any Application in wave `-1` or higher tries to reference it.
- SUC Plans are a separate Application (wave `2`) from the controller itself (wave `1`), so the CRD is guaranteed to exist before the Plan CR is applied.
- CCM (wave 2) must sync before CSI (wave 3) — CSI requires ProviderID on the node, which CCM sets.
- `cert-manager-issuers` Application (wave 4) is separate from the `cert-manager` Application (wave 1) for the same reason SUC Plans are separate from the controller — `ClusterIssuer` CRD doesn't exist until cert-manager finishes installing. Separate Application with `selfHeal: true` retries until the CRD is present.
- Cilium Gateway API always creates a Service of type `LoadBalancer`. hcloud CCM will provision a real Hetzner Load Balancer for it. Do not create `Gateway` resources without intending to pay for one.

**On modules and Terragrunt:** the flat single-module layout is correct through Phase 5. Two natural upgrade paths: (1) **child modules** for stamping identical resource groups; (2) **Terragrunt layers** for isolated state per concern. Neither is needed until the pain of not having them is felt.

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
  - Example: `curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.32.3+k3s1" INSTALL_K3S_EXEC="server --cluster-init --disable traefik --disable servicelb" sh -`
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
  - Allow inbound: SSH from your IP only, port 6443 (k3s API) from your IP only
  - Block all other inbound. Outbound: unrestricted.
  - Firewall rules use IPv6 CIDR — kubeconfig must point to the server's IPv6 address so kubectl traffic matches the allowed source
- [x] Firewall attached to server via `hcloud_firewall_attachment`
- [x] Deletion and rebuild protection enabled on the server resource
  - `delete_protection = true` and `rebuild_protection = true` on `hcloud_server`
  - A `tofu destroy` will explicitly fail rather than silently nuke the server
  - You must set these to `false` first before any intentional destructive operation — deliberate friction
- [x] Inter-node traffic encryption
  - **Cilium path chosen (Phase 5):** WireGuard skipped here — Cilium handles encryption natively via eBPF/WireGuard. `--flannel-backend=wireguard-native` must NOT be set.
- [x] Unattended OS security updates configured via cloud-init (`unattended-upgrades`)
  - Auto-patches the OS without SSH. Set in `user_data` at provision time via `init.sh.tpl`.
- [x] k3s auto-upgrade via `system-upgrade-controller`
  - SUC v0.19.2 deployed via ArgoCD, pointing at upstream repo at pinned tag
  - Plan targets `https://update.k3s.io/v1-release/channels/stable` — upgrades fire automatically when stable channel advances
  - Plans are a separate ArgoCD Application (wave 2) to guarantee CRD exists before Plan CR is applied
- [x] Automatic node reboots via `kured`
  - kured 1.21.0 (chart 5.11.0) deployed via ArgoCD into `kube-system`
  - `useRebootSentinelHostPath: true` (default) mounts host `/var/run` at `/sentinel` inside container
  - Do NOT set `rebootSentinel: /var/run/reboot-required` — that path is inside the container, not the hostPath mount point (`/sentinel/reboot-required`)
  - Maintenance window: 02:00–04:00 IST; timezone `Asia/Kolkata`
  - `metrics.create: true` with `release: kube-prometheus-stack` label set from the start

---

## Phase 3 — observability ✅

Observability is non-negotiable from the start. Without it, you have no visibility into what the cluster is doing unless you actively `kubectl` into it — which breaks the boring-ops rule.

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
  - Network `10.0.0.0/16`, subnet `10.0.0.0/24` (`eu-central`), control plane at `10.0.0.2` on `enp7s0`
  - Must exist before adding a second node — do not defer
- [x] k3s configured with `--node-ip`, `--disable-cloud-controller`, `--cloud-provider=external`, `--tls-san`
  - Set at provision time in `init.sh.tpl` via `config.yaml`
- [x] Hetzner Cloud Controller Manager (CCM) v1.30.1 deployed via ArgoCD (wave 2)
  - hcloud secret (`token` + `network` keys) deployed as SealedSecret in `kube-system` (wave 1, before CCM)
  - ProviderID confirmed on node: `hcloud://<server-id>`
  - `networking.enabled: true` with `clusterCIDR: 10.42.0.0/16` (k3s default pod CIDR)
  - PodMonitor enabled with `release: kube-prometheus-stack` label
- [x] Hetzner CSI driver v2.5.1 deployed via ArgoCD (wave 3)
  - StorageClass `hcloud-volumes` created; `defaultStorageClass: false` to avoid conflict with k3s's `local-path` default
  - `volumeBindingMode: WaitForFirstConsumer` — volume provisioned in correct datacenter after pod scheduling
  - `allowVolumeExpansion: true`
  - ServiceMonitor enabled with `release: kube-prometheus-stack` label
  - Always specify `storageClassName: hcloud-volumes` explicitly in PVC specs — never rely on default
- [x] Persistent storage for Prometheus, Grafana, Alertmanager on Hetzner Volumes
  - Prometheus: 10Gi volume, `retentionSize: 6GiB`, `retention: 7d`
  - Grafana: 10Gi volume
  - Alertmanager: 10Gi volume
  - All three volumes confirmed in Hetzner project (`hcloud volume list`), attached to `hetzner-k3s-cp-1` in `hel1`
  - **Note:** Volumes are location-scoped. A volume in `hel1` cannot attach to a node in another datacenter. CSI + `WaitForFirstConsumer` handles placement automatically; no manual node affinity needed for single-location clusters.
  - **Note:** Volumes are NOT managed by OpenTofu — they are dynamically provisioned by CSI. If the cluster is destroyed and rebuilt, existing volumes are orphaned and new ones are created. Full backup/restore requires Velero (Phase 8).

---

## Phase 5 — ingress + TLS ✅ _(partial — Gateway wiring deferred)_

**Path A — Cilium + Gateway API** _(chosen)_

Cilium is a full CNI replacement for Flannel. Adopting it means rebuilding the node with different k3s install flags before Phase 5 begins.

k3s install flags required:

```
--flannel-backend=none
--disable-kube-proxy
--disable-network-policy
--disable traefik
--disable servicelb
```

Cilium takes over: CNI, kube-proxy replacement (eBPF-native), network policy, WireGuard encryption, Gateway API, and observability via Hubble.

Operational note: eBPF means `iptables -L` is useless for debugging — use `cilium` CLI and Hubble instead. Before running `k3s-killall.sh` or `k3s-uninstall.sh`, manually remove `cilium_host`, `cilium_net`, and `cilium_vxlan` interfaces or host networking will break.

- [x] Node rebuilt with `--flannel-backend=none --disable-kube-proxy --disable-network-policy --disable-kube-proxy` flags
  - k3s `config.yaml` set at provision time via `init.sh.tpl`; node never ran Flannel
- [x] Gateway API CRDs (standard channel v1.4.1) installed before Cilium bootstrap
  - Handled by `helmfile` via `gateway-api-crds` synthetic release; Cilium release has `needs: kube-system/gateway-api-crds`
- [x] Cilium v1.19.3 (chart 1.19.3) deployed via helmfile bootstrap, adopted by ArgoCD
  - `kubeProxyReplacement: true`, `routingMode: native`, WireGuard encryption enabled
  - `hubble.tls.auto.method: cronJob` — deterministic cert renders, no ArgoCD OutOfSync churn
  - Hubble Relay + UI enabled; live flow visibility confirmed via Hubble UI
  - `cgroup.autoMount.enabled: false`, `cgroup.hostRoot: /sys/fs/cgroup` — uses host systemd cgroup mount
  - `selfHeal: true` on ArgoCD Application; `ServerSideApply=true` for helmfile adoption
- [x] `cert-manager` v1.19.4 (chart v1.19.4) deployed via ArgoCD (wave 1)
  - Gateway API support enabled via file-based `ControllerConfiguration` (`enableGatewayAPI: true`)
  - CRDs installed and managed by Helm (`crds.enabled: true`)
- [x] `cert-manager-issuers` Application deployed at wave 4 (separate from cert-manager to avoid CRD race)
  - `self-signed` ClusterIssuer deployed; cert issuance smoke-tested (`Certificate` → `Ready=True`, Secret populated)
- [ ] Domain acquired → add `letsencrypt-staging` + `letsencrypt-prod` ClusterIssuers
- [ ] `hcloud_load_balancer` provisioned (via Tofu) for ingress traffic
- [ ] `Gateway` + `HTTPRoute` resources wired up for real workloads (Grafana, ArgoCD)
  - Cilium Gateway creates a Service/LoadBalancer → hcloud CCM provisions a real Hetzner LB → do not create Gateway resources before the LB is planned and paid for

**Path B — Traditional ingress controller** _(not chosen)_

---

## Phase 6 — multi-node scale-out

- [ ] `hcloud_server` resources for worker nodes added with `for_each`
- [ ] Worker nodes join cluster via pre-generated k3s token
- [ ] Additional control plane nodes added (must be odd: 1 → 3 → 5)
- [ ] `hcloud_load_balancer` added for k3s API HA
  - Private LB IP: `10.0.0.100`; used by joining nodes and Cilium.
  - Public LB IP is included in K3s TLS SANs so admin access can later move to the LB without rebuilding nodes.
  - Current admin access remains Option B: kubeconfig points at the bootstrap CP public IPv6, and CP node `6443` is restricted to `home_ip`.
  - Tradeoff: cluster control-plane access is HA internally; admin access is locked down but not HA until a later access phase.
- [ ] Cluster Autoscaler deployed
- [ ] Terragrunt introduced for state isolation between layers

---

## Phase 7 — GitOps ✅

- [x] ArgoCD v3.3.9 (helm chart 9.5.11) bootstrapped via helmfile (`kubernetes/bootstrap/`)
  - `helmfile.yaml` + `values/bootstrap.yaml.gotmpl` + `sops exec-env` for admin password
  - Admin password stored as bcrypt hash in SOPS-encrypted `bootstrap/secrets/helmfile.secrets.yaml`
  - `server.insecure: true` set — TLS termination deferred to Cilium Gateway (Phase 5)
  - `just argocd-ssh-bootstrap` and `just argocd-root-bootstrap` targets defined
- [x] ArgoCD self-managing
  - `infra/argocd/application.yaml` applied via root app; ArgoCD owns its own upgrades
  - `ServerSideApply=true` sync option set; no auto-sync, no auto-prune on self-managing app
- [x] Sealed Secrets v2.18.5 deployed as first ArgoCD Application
  - `infra/sealed-secrets/application.yaml`; controller in `kube-system` as `sealed-secrets-controller`
  - `fullnameOverride` set so `kubeseal` CLI works without extra flags
  - Master key backed up offline (encrypted). Losing it = all sealed secrets permanently unrecoverable.
- [x] `sealed-secrets-cert.pem` fetched and committed to repo
  - `kubeseal --fetch-cert --controller-name sealed-secrets-controller --controller-namespace kube-system > kubernetes/sealed-secrets-cert.pem`
- [x] GitHub deploy key generated, added to repo as read-only deploy key, private key sealed and applied
  - Stored as SOPS-encrypted `bootstrap/secrets/argocd-repo-ssh.sops.yaml`
  - Applied once via `just argocd-ssh-bootstrap` (decrypts + `kubectl apply`)
  - Label: `argocd.argoproj.io/secret-type: repository`
- [x] Root Application wires the GitOps loop
  - `root-application.yaml` applied once via `just argocd-root-bootstrap`
  - Tracks `kubernetes/` path via kustomize; owns all Application/AppProject manifests
  - App-of-Apps pattern (not ApplicationSet) — simpler, sufficient for current scale
- [x] AppProject/infra created with sync wave `-2`
  - Ensures project exists before any Application in wave `-1` or higher references it
  - Destinations: `argocd`, `kube-system`, `system-upgrade`
- [x] system-upgrade-controller v0.19.2 deployed via ArgoCD
  - Deployed from upstream GitHub repo at pinned tag (no Helm chart exists)
  - `ServerSideApply=true` required — cluster-scoped RBAC resources need it
  - k3s upgrade Plans in separate Application at wave `2`
- [x] kured 1.21.0 deployed via ArgoCD
  - Helm chart 5.11.0 from `kubereboot/charts`
  - First OS reboot (pending since Phase 2) handled cleanly by kured

---

## Phase 8 — backups _(deliberately deferred)_

Backups are deferred until the declarative + immutable workflow is fully internalised.

**etcd snapshots** — k3s ships snapshots to Hetzner Object Storage (S3-compatible). Single flag change. Covers cluster state only, not persistent volume data.

**Velero** — backs up both Kubernetes manifests and persistent volume data via CSI snapshots. The production-grade answer for full cluster backup and disaster recovery.

A restore drill must be performed when both are in place — an untested backup is not a backup.

- [ ] k3s etcd snapshots configured to ship to Hetzner Object Storage
- [ ] Velero deployed with Hetzner CSI snapshot support
- [ ] Hetzner Object Storage bucket created, access credentials scoped to backup use only
- [ ] Restore drill completed and documented

---

## Hard-won lessons

### Bug 1 — SealedSecret CRD deadlock (the one that cost a night)

**Symptom:** Root app stuck in `SyncFailed`. `sealed-secrets` Application never gets created. Error: `The Kubernetes API could not find bitnami.com/SealedSecret`. Happens on every fresh sync or cluster rebuild.

**Why sync waves don't help:** Sync waves control the order ArgoCD applies manifests _within a single sync_. Setting `sync-wave: "-2"` on the `sealed-secrets` Application object means that object gets applied first — but applying an Application object just tells ArgoCD "go manage this". The actual Helm chart install, which creates the `SealedSecret` CRD, happens asynchronously in a separate sync loop. ArgoCD does not wait for a child Application's sync to complete before moving to the next wave. So by the time wave 0 tries to apply raw `SealedSecret` manifests, the CRD still doesn't exist.

```
Wave -2: root applies sealed-secrets Application object   ← instant
Wave  0: root applies SealedSecret manifests              ← instant
         ... meanwhile sealed-secrets chart is still installing
         ... CRD doesn't exist yet
         BOOM
```

**Fix:** Raw `SealedSecret` manifests must never live in the root kustomization or any kustomization that root renders directly. Move them into their own dedicated Application with `selfHeal: true`. That Application retries independently until the CRD exists and the sealed-secrets controller is healthy.

**Rule:** The root kustomization must only contain Application objects and CRD-free resources. Any resource whose kind is defined by a CRD installed by a child Application must live in its own Application.

---

### Bug 2 — Application self-reference conflict ("two owners")

**Symptom:** ArgoCD reports a resource ownership conflict on the `hcloud-secret` Application object — it is simultaneously owned by `root` and by `hcloud-secret` itself.

**Why it happens:** The `hcloud-secret` Application pointed its source path at `kubernetes/infra/hcloud-secret/`. Without a `kustomization.yaml` in that directory, ArgoCD uses directory source mode, which picks up _every YAML file in the path_ — including `application.yaml` itself. So `hcloud-secret` was trying to deploy the very Application object that defines it, which `root` already owns via the infra kustomization chain. Two owners, one resource, conflict.

**Fix:** Add a `kustomization.yaml` inside the directory that explicitly lists only the intended resources:

```yaml
# kubernetes/infra/hcloud-secret/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - sealed-secret.yaml # application.yaml is intentionally absent
```

ArgoCD switches from "deploy everything" to "deploy exactly what kustomize says". The `application.yaml` sits in the directory but is invisible to the Application's sync.

**Rule:** Whenever an Application's source path is a directory in your own Git repo, that directory must contain a `kustomization.yaml` that explicitly controls what gets deployed. Never mix Application objects and their managed resources in the same directory without one.

---

## Key constraints to remember

- **State files** (`*.tfstate`): gitignored always, even though encrypted. Never commit.
- **ghcr.io**: no IPv6 support. Use Docker Hub for all images.
- **GitHub releases**: IPv4-only. IPv4 must be enabled on the server at bootstrap time.
- **etcd quorum**: control plane count must always be odd (1, 3, 5).
- **Private network**: set up before adding a second node, not after.
- **k3s version**: always pinned via `INSTALL_K3S_VERSION`. Never install latest implicitly.
- **`.tofu` extension**: used intentionally for OpenTofu-specific syntax. Use the OpenTofu VS Code extension.
- **No direct `kubectl apply`**: once ArgoCD is live, all deployments go through it. The only exceptions are the one-time bootstrap steps (`just argocd-ssh-bootstrap`, `just argocd-root-bootstrap`).
- **Nodes are cattle, not pets**: wanting to SSH in to fix something is a signal to improve observability or automation.
- **Deletion protection**: enabled on all servers with real workloads. Intentional destruction requires explicitly removing it first.
- **Cilium vs Flannel**: mutually exclusive at install time. Cannot migrate without a full rebuild.
- **Sealed Secrets master key**: back it up offline immediately after first deploy. Losing it = losing all sealed secrets permanently.
- **SealedSecrets are cluster-scoped by default**: a secret sealed for one cluster cannot be decrypted by another. Keep the master key backup for disaster recovery restore.
- **ArgoCD self-management**: never set auto-prune on the self-managing Application. Always use `ServerSideApply=true`.
- **helmfile is bootstrap-only**: its only job was getting ArgoCD running. All subsequent deployments go through ArgoCD.
- **AppProject sync wave**: always set `-2` on AppProject so it lands before any Application that references it.
- **SUC RBAC**: `ServerSideApply=true` is required on the SUC Application. Without it, ClusterRole/ClusterRoleBinding may fail silently, and the pod starts with no permissions. If this happens after the fact, `kubectl rollout restart` is the fix — RBAC changes do not trigger pod restarts automatically.
- **kured sentinel path**: `useRebootSentinelHostPath: true` (default) mounts host `/var/run` at `/sentinel` inside the container. The correct sentinel path inside the container is `/sentinel/reboot-required`. Do not override `rebootSentinel` to `/var/run/reboot-required` — that points at the container's own `/var/run`, not the host mount.
- **ArgoCD Last Sync vs Sync Status**: "Synced to [commit]" means desired state matches live state. "Last Sync" only advances when ArgoCD actually applies a diff. A values-only change that ArgoCD applies at the child app level will not advance the root app's Last Sync — this is correct behaviour.
- **Hetzner Volumes are location-scoped**: a volume in `hel1` can only attach to a server in `hel1`. CSI + `WaitForFirstConsumer` handles placement automatically. For multi-location clusters, stateful workloads must be pinned via node affinity or a distributed storage solution (e.g. Longhorn) is required.
- **CSI volumes are not managed by OpenTofu**: dynamically provisioned volumes are orphaned on cluster rebuild. Velero (Phase 8) is required for full disaster recovery.
- **StorageClass default**: `hcloud-volumes` is intentionally not set as the default to avoid conflict with k3s's `local-path` default. Always specify `storageClassName: hcloud-volumes` explicitly in PVC specs.
- **Cilium Gateway API creates real Hetzner LBs**: any `Gateway` resource triggers Cilium to create a `Service/LoadBalancer`, which hcloud CCM immediately reconciles into a paid Hetzner Load Balancer. There is no "no-LB" GatewayClass in Cilium. Do not create `Gateway` resources without intending to pay for the LB.
- **cert-manager Gateway API support**: not a feature flag since v1.15 — must be enabled via file-based `ControllerConfiguration` (`enableGatewayAPI: true`). Without it, `cert-manager.io/cluster-issuer` annotations on `Gateway` resources are silently ignored.
- **cert-manager CRD-dependent resources**: `ClusterIssuer`, `Certificate`, etc. must live in a separate Application with `selfHeal: true`, not in the same Application as the cert-manager Helm release. The CRDs don't exist until cert-manager finishes installing; `selfHeal` handles the retry automatically.
- **Hubble TLS certs**: set `hubble.tls.auto.method: cronJob` (not the default `helm`). Helm's `genCA` is non-deterministic — every render produces different cert material, making ArgoCD perpetually OutOfSync and silently rotating certs every ~3 minutes with `selfHeal: true`.
