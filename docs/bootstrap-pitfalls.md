# Bootstrap Pitfalls

Every issue we hit during the first end-to-end cluster build, what caused it, and the resolution. Read this before doing a fresh bootstrap or onboarding the cluster on a new machine.

Each entry: **Symptom** → **Cause** → **Fix**.

---

## SOPS-encrypted Secret manifests carry stale runtime metadata

**Symptom.** `just hcloud-secret-bootstrap` (or any `kubectl apply` of a SOPS-decrypted Secret) fails with:

```
Error from server (Conflict): error when applying patch:
... Operation cannot be fulfilled on secrets "hcloud":
the object has been modified; please apply your changes to the latest version
```

Even worse, sometimes the apply succeeds and the Secret silently disappears minutes later because of orphaned `ownerReferences`.

**Cause.** The SOPS source file was originally captured with `kubectl get secret -o yaml > foo.yaml` from a prior cluster. That output includes:

- `creationTimestamp`
- `resourceVersion`
- `uid`
- `ownerReferences`

`resourceVersion` triggers optimistic-concurrency conflicts on apply. `ownerReferences` is worse — once the Secret is created, the GC controller looks for the named owner UID, fails to find it (different cluster), and **deletes the Secret as orphaned**.

**Fix.**

1. `sops kubernetes/bootstrap/secrets/hcloud-ccm-secret.sops.yaml` (opens decrypted in `$EDITOR`).
2. Remove from `metadata:`: `creationTimestamp`, `resourceVersion`, `uid`, the entire `ownerReferences` block. Keep only `name` and `namespace`.
3. Save (re-encrypts on close).
4. `kubectl -n kube-system delete secret hcloud --ignore-not-found` to wipe the polluted live state.
5. Re-run the bootstrap recipe.

**Prevention.** When adding new SOPS-encrypted Secret files, hand-write them or pipe through `kubectl create secret ... --dry-run=client -o yaml` (which does not include runtime metadata). Apply the same scrub to `argocd-repo-ssh.sops.yaml` and `sealed-secrets-master-key.sops.yaml` if regenerating those.

**Hardening.** The Justfile bootstrap recipes can additionally use `kubectl apply --server-side --force-conflicts` to bypass the `resourceVersion` issue (won't help with `ownerReferences`, that still needs to be stripped at the source).

---

## Sealed-secrets ordering: root Application applied before master key

**Symptom.** SealedSecrets stuck in `False` / `no key could decrypt secret`. The cluster has **two** active keys but neither decrypts.

```
$ kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key=active
NAME                      TYPE                DATA   AGE
sealed-secrets-keybnqjp   kubernetes.io/tls   2      6m12s
sealed-secrets-keykck8s   kubernetes.io/tls   2      6m47s
```

**Cause.** When `just argocd-root-bootstrap` runs before `just restore-sealed-secrets-key`, the sealed-secrets controller starts up, finds no master key in `kube-system`, and **auto-generates a fresh one**. When the user later applies the real master key, it shows up as a second active-labeled Secret — but the controller's key registry doesn't always pick up newly-added keys cleanly mid-run, so SealedSecrets keep failing.

**Fix.**

```sh
kubectl -n kube-system rollout restart deploy/sealed-secrets-controller
kubectl -n kube-system rollout status deploy/sealed-secrets-controller
```

The fresh pod re-lists active-labeled Secrets at startup, registers both keys, and re-attempts every SealedSecret. Within seconds, ones encrypted with your master key flip to `Synced=True`.

**Prevention.** Run step 4 of the bootstrap (`just restore-sealed-secrets-key`) **before** step 5 (`just argocd-root-bootstrap`).

---

## A SealedSecret has only the auto-generated key working

**Symptom.** Some SealedSecrets unseal after the controller restart, but a specific one (e.g. `kube-system/hcloud`) stays `no key could decrypt secret` while others go green.

**Cause.** That SealedSecret was sealed against a *different* master key than the one in your SOPS file — typically a key from an older cluster lifecycle that no longer exists. The "no key could decrypt" message is identical for two cases (no working key OR scope mismatch), making this confusing.

**Fix.** Re-seal it against the live controller using plaintext you already have access to:

```sh
sops --decrypt kubernetes/bootstrap/secrets/hcloud-ccm-secret.sops.yaml > /tmp/hcloud.yaml
# verify metadata.name and metadata.namespace are set in /tmp/hcloud.yaml
kubeseal --controller-namespace kube-system \
         --controller-name sealed-secrets-controller \
         --format yaml < /tmp/hcloud.yaml > /tmp/hcloud-sealedsecret.yaml
shred -u /tmp/hcloud.yaml
# replace kubernetes/infra/hcloud-secret/sealedsecret.yaml with /tmp/hcloud-sealedsecret.yaml
# commit, push; ArgoCD reconciles
```

Important: `metadata.namespace` **must** be set on the plaintext Secret before sealing, or `kubeseal` produces a SealedSecret with no namespace, which fails to apply with a different error later.

---

## SealedSecret refuses to manage a pre-existing Secret

**Symptom.**

```
failed update: Resource "hcloud" already exists and is not managed by SealedSecret
```

**Cause.** During bootstrap, `just hcloud-secret-bootstrap` creates a vanilla Secret named `hcloud` (so hccm can start). Later, the SealedSecret in the GitOps tree tries to take ownership of the same Secret. By default, the sealed-secrets controller **refuses to overwrite** a Secret it didn't create, unless that Secret is annotated with `sealedsecrets.bitnami.com/managed: "true"`.

**Fix (option A — what we did).** Delete the bootstrap Secret, let the controller create a fresh managed one:

```sh
kubectl -n kube-system delete secret hcloud
kubectl -n kube-system rollout restart deploy/sealed-secrets-controller
```

The rollout restart is necessary because the controller is event-driven on SealedSecret spec changes, not on the underlying Secret's deletion — without a restart, it won't realize the obstruction is gone.

**Fix (option B — cleaner, no deletion gap).** Pre-annotate the bootstrap Secret so the controller adopts it without conflict:

```sh
kubectl -n kube-system annotate secret hcloud sealedsecrets.bitnami.com/managed=true --overwrite
```

Worth folding into `hcloud-secret-bootstrap` in the Justfile if rebuilding from scratch is on the menu.

---

## Helmfile→ArgoCD release-name mismatch breaks the Deployment selector

**Symptom.**

```
Deployment.apps "hcloud-cloud-controller-manager" is invalid:
spec.selector: Invalid value: ...: field is immutable
```

ArgoCD retries forever; the Deployment can't be updated.

**Cause.** Helm chart templates derive selector labels from `.Release.Name`:

```yaml
selector:
  matchLabels:
    app.kubernetes.io/instance: <release-name>
    app.kubernetes.io/name: hcloud-cloud-controller-manager
```

`Deployment.spec.selector` is **immutable** in Kubernetes. If `kubernetes/bootstrap/helmfile.yaml` uses `name: hccm` and `kubernetes/infra/hcloud-ccm/application.yaml` uses `helm.releaseName: hcloud-ccm`, the rendered selector differs and ArgoCD cannot reconcile.

**Fix.** Align the names. Cheapest direction:

```yaml
# kubernetes/infra/hcloud-ccm/application.yaml
helm:
  releaseName: hccm   # was: hcloud-ccm
```

The Application object name (`metadata.name: hcloud-ccm`) doesn't need to change — only the Helm `releaseName` (which is just a template input).

**Prevention.** When adopting a helmfile release into ArgoCD, copy the helmfile `name:` directly into `helm.releaseName:`. They are not separate concepts; treat them as one value.

---

## Cilium `cilium-ca` and `hubble-server-certs` perpetually OutOfSync

**Symptom.** ArgoCD's `cilium` Application stays `OutOfSync` forever; the diff is always on `Secret/kube-system/cilium-ca` and `Secret/kube-system/hubble-server-certs`. With `selfHeal: true`, ArgoCD re-syncs every ~3 min, silently rotating both certs each time.

**Cause.** The Cilium chart's default `hubble.tls.auto.method: helm` uses Helm's Sprig `genCA`/`genSignedCert` functions to generate cert material at template-render time. These are **non-deterministic** — every render produces different material. ArgoCD treats this as drift.

**Fix.** Switch to certgen-managed certs:

```yaml
# kubernetes/infra/cilium/values.yaml
# kubernetes/bootstrap/values/cilium.yaml.gotmpl
hubble:
  tls:
    auto:
      method: cronJob
```

The chart deploys a `hubble-generate-certs` Job + CronJob (default schedule `0 0 1 */4 *` — every 4 months). The Job creates `cilium-ca` and `hubble-server-certs` once; the CronJob rotates both periodically. Hubble hot-reloads cert changes without dropping connections.

**Verify.**

```sh
kubectl -n kube-system get secret cilium-ca hubble-server-certs \
  -o custom-columns='NAME:.metadata.name,MANAGED-BY:.metadata.annotations.app\.kubernetes\.io/managed-by'
# both should show: certgen
```

**Note.** If/when ClusterMesh is enabled, set `clustermesh.apiserver.tls.auto.method: cronJob` separately — that controls a different set of certs.

---

## quay.io 502 Bad Gateway during Cilium image pull

**Symptom.** Cilium pods stuck `ImagePullBackOff` immediately after install:

```
Failed to pull image "quay.io/cilium/cilium:v1.19.3@sha256:...":
... unexpected status from HEAD request to https://quay.io/v2/...:
502 Bad Gateway
```

**Cause.** quay.io itself is having an upstream issue. The 502 comes from quay's CDN — DNS, TLS handshake, and the TCP connection are all fine; the registry's edge can't reach origin. Cilium's images live only on quay.io (no docker.io or ghcr.io mirror), so there's no easy registry swap.

**Fix.**

1. Confirm it's not local: `ssh root@<cp-ipv6> 'crictl pull quay.io/cilium/cilium:v1.19.3'`. Same 502 → upstream.
2. Check https://status.quay.io.
3. **Wait.** Quay 502s typically resolve in 10–60 minutes. Cilium pods retry forever with ~5 min backoff cap; they recover automatically.
4. To skip the backoff once quay is back: `kubectl -n kube-system delete pod -l k8s-app=cilium -l io.cilium/app=operator -l k8s-app=cilium-envoy` (forces immediate retry).

**Don't** Ctrl-C and re-run `just argocd-bootstrap` — helmfile is still tracking the in-progress release. Let it sit; it picks up where it left off once the registry recovers.

---

## Gateway API CRDs missing — chart render fails

**Symptom.** Helmfile errors with something like `no matches for kind "GatewayClass"` when applying the cilium chart. Or the chart applies but `cilium-operator` logs `GatewayAPI resources not found`.

**Cause.** Cilium's chart with `gatewayAPI.enabled: true` renders `GatewayClass` resources, but **does not install** the Gateway API CRDs themselves. Cilium 1.19 expects the **standard channel of v1.4.1**.

**Fix.** Already wired in: `kubernetes/bootstrap/gateway-api-crds/kustomization.yaml` references the upstream `standard-install.yaml`, helmfile wraps the kustomization as a synthetic chart, and the cilium release `needs: kube-system/gateway-api-crds` so install order is enforced. If bumping Cilium past 1.19 in the future, **bump the URL** in that kustomization to match the new supported Gateway API version.

**Note.** This setup requires the `kustomize` CLI on `PATH` — already in `devbox.json`. If running outside `devbox shell`, you'll get a less-helpful error from helmfile.

---

## `kustomize` not on PATH

**Symptom.** `just argocd-bootstrap` fails with helmfile complaining about kustomize being unavailable when processing the gateway-api-crds release.

**Cause.** Running outside `devbox shell`. Devbox manages all CLIs; kustomize is one of them.

**Fix.** `devbox shell`, then re-run.

---

## hccm working but `hcloud-secret` ArgoCD app shows Degraded

**Symptom.** `kubectl get applications -n argocd` shows `hcloud-secret` as `Synced/Degraded`. But hccm itself is `Running`.

**Cause.** The Secret was created by `just hcloud-secret-bootstrap` (vanilla `kubectl apply`). hccm reads the live Secret happily. But the `hcloud-secret` ArgoCD Application is responsible for the *SealedSecret*, which is failing to unseal for one of the reasons above (wrong key, ownership conflict, controller didn't reload).

**Fix.** Walk through the SealedSecret-related entries in this doc. Once the SealedSecret unseals, the resulting Secret update is in-place — hccm doesn't need to restart.

---

## ArgoCD apps stay `OutOfSync, Healthy` after adoption

**Symptom.** `argocd`, `cilium`, `hcloud-ccm` show `OutOfSync` even though everything works.

**Cause.** Field-manager ownership noise from the helmfile→ArgoCD adoption handoff under `ServerSideApply`. The field values match; field manager identities differ.

**Fix.** One-time per app, once you're confident the diff is just ownership noise:

```sh
argocd app sync cilium --replace
argocd app sync hcloud-ccm --replace
argocd app sync argocd --replace
```

**Or** in the UI, click `Sync` → check "Replace". Subsequent reconciles will be clean.

Don't do this without first reading the diff (`argocd app diff cilium`) — `--replace` *will* overwrite live state, so make sure the diff is what you expect.

---

## Quick reference: things that look broken but aren't

- `coredns`, `local-path-provisioner`, `metrics-server` `Pending` early in bootstrap → expected, no CNI yet, they schedule once Cilium is up
- `Warning DNSConfigForming Nameserver limits were exceeded` events → benign; kubelet caps pod resolv.conf at 3 nameservers, Hetzner provides exactly 3
- Node `NotReady` for ~30s after Cilium install → kubelet re-evaluates after CNI config is written, brief gap
- `ImagePullBackOff` on Cilium right after install → check the 502 entry above before assuming local network problem
