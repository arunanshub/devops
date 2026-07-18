# App Correctness Audit — arunanshu.dev

Living audit of application- and workload-level correctness against upstream
best practices. Started 2026-07-18 with the `arunanshu.dev` Next.js app and its
Kubernetes manifests; will be extended to other applications and to the cluster
as a whole in later passes.

Each finding is graded and grounded in a citable source. The Next.js findings
were verified against the **bundled docs of the exact build in use**
(`next@16.3.0-preview.6`, `node_modules/next/dist/docs/`) and the build's own
type definitions (`config-shared.d.ts`) — not general/online docs, which lag
this preview.

## Scope of this pass (2026-07-18)

- App repo: `arunanshu.dev` — `next.config.ts`, `Dockerfile`, `env.ts`,
  `instrumentation*.ts`, `package.json`, app/component source.
- Manifests: `kubernetes/base/apps/arunanshu-dev/` (deployment, service,
  httproute, scaledobject, vpa, pdb, middleware, vmservicescrape, namespace).
- Angle: Next.js self-hosting correctness + Node runtime optimization.

Not yet covered (future passes): other apps, platform/monitoring workloads,
cluster-wide policy (NetworkPolicy coverage, RBAC, PSA), CI/CD supply chain.

---

## What is already correct (confirmed, keep as-is)

These were checked and are right; recorded so a later pass does not re-litigate
them.

- **`output: standalone`** via validated env, distroless `nodejs26` runner,
  non-root uid 65532, `readOnlyRootFilesystem` + `emptyDir` at `/tmp` and
  `/app/.next/cache`. Matches the self-hosting requirement that sharp and the
  incremental cache have writable paths.
- **`experimental.isrFlushToDisk: false`** — correct and non-obvious. With a
  read-only root, Next's default disk flush of revalidated output would `EROFS`.
  Keeping revalidated entries in memory while serving baked pages from disk is
  the right combination. Key confirmed present in this build's
  `ExperimentalConfig`.
- **Version-skew protection** — `deploymentId` + `NEXT_DEPLOYMENT_ID` baked at
  build time is exactly what the self-hosting "Version Skew" section prescribes
  (`?dpl=` on assets, `x-deployment-id` on navigation → hard reload on
  mismatch). `minReadySeconds: 30` gives the Cloudflare edge time to warm new
  content-hashed chunk URLs.
- **Reverse proxy** — Cloudflare → Traefik satisfies "don't expose Next
  directly." `compress: false` at origin with Traefik doing `br`/`gzip`,
  including `text/x-component` (RSC payloads), is correct.
- **Config keys valid for this exact build** — every key in `next.config.ts`
  checked against `config-shared.d.ts`. `cacheComponents`, `typedRoutes`,
  `partialPrefetching`, `reactCompiler` are correctly used at **top-level**
  (the `experimental.*` forms are `@deprecated` aliases in this build); the rest
  are correctly nested under `experimental`.
- **Instrumentation split** — the `NEXT_RUNTIME === 'nodejs'` guard plus dynamic
  import keeps `prom-client`/`node:http` out of the Edge bundle, matching the
  instrumentation guide. Metrics served on a side port (9091), absent from the
  HTTPRoute, scraped in-cluster only.
- **sharp availability** — glibc x64 prebuilt (`@img/sharp-linux-x64`,
  `@img/sharp-libvips-linux-x64`) present in the lockfile and matches the
  amd64/glibc distroless runner.

---

## Findings

### 1. [Medium] `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` unset, with a live Server Action

**Source:** self-hosting guide, "Multi-Server Deployments → Server Functions
encryption key":
> By default, a unique encryption key is generated for each build… all instances
> must use the same encryption key. Otherwise, a Server Function encrypted by one
> instance cannot be decrypted by another, causing "Failed to find Server
> Action" errors.

**Evidence:** `'use server'` action `getMyName`
(`components/client-side-data-fetching/actions.ts`) is live — rendered via
`<ServerActionFetcher>` in the published post
`content/blog/next-server-actions-client-side-data-fetching.mdx`.

**Impact:** each build bakes a *random* key. During a rolling update, a visitor
whose HTML came from the old build POSTs an action to a new-build pod →
decryption fails. `deploymentId` softens this (forces a reload rather than a
hard error), but the doc's intended fix is a **stable key across builds**.

**Proposed fix:** inject a fixed key (SealedSecret in devops → build ARG →
baked ENV) so every image shares one key. Low effort, closes the gap cleanly.
Decision needed: where the key lives / how it reaches the build.

### 2. [Medium] glibc + sharp memory (the one clear Node-optimization gap)

**Source:** self-hosting guide, Image Optimization:
> On glibc-based Linux systems, Image Optimization may require additional
> configuration to prevent excessive memory usage.

**Evidence:** runner is glibc (`distroless/nodejs26-debian13`); runtime image
optimization runs sharp (writes to `.next/cache`); container memory limit is
`384Mi`.

**Impact:** glibc's per-thread malloc arenas inflate RSS under sharp's threaded
work; against a 384Mi ceiling that is a real OOM risk.

**Proposed fix:** set `MALLOC_ARENA_MAX=2` in the container env. Standard
mitigation, no downside. (jemalloc would be better but is not available in
distroless without rebuilding the base.) Do **not** hardcode
`NODE_OPTIONS=--max-old-space-size` — it would fight the VPA's memory resizing
(64Mi→512Mi); `MALLOC_ARENA_MAX` addresses the actual concern.

### 3. [Low/Info] Multi-pod cache is per-pod — correct for now, revisit on trigger

**Source:** self-hosting guide, "Configuring Caching" and "Multi-Instance Cache
Coordination."

**Evidence:** 2–8 replicas with `use cache` (home/blog/tags) +
`isrFlushToDisk: false` and no shared `cacheHandler`. No `cacheLife`,
`cacheTag`, `revalidateTag`, or `revalidatePath` anywhere in the app.

**Assessment:** benign today. Every cached entry derives from build-baked MDX —
identical across pods, no runtime data source, no on-demand revalidation. A
Redis `cacheHandler` would be over-engineering now.

**Trigger to revisit:** adding a runtime data source, or any on-demand
`revalidateTag`/`revalidatePath`. At that point add a shared `cacheHandler`
(`cacheMaxMemorySize: 0`) and implement `refreshTags()` for cross-pod tag
invalidation.

### 4. [Low] No `preStop` / graceful-drain hook on rollout

**Source:** self-hosting guide, `after` / graceful shutdown (10–30s drain on
`SIGTERM`).

**Evidence:** deployment sets no `terminationGracePeriodSeconds` (default 30s,
acceptable) and no `preStop`.

**Impact:** without a `preStop` delay, a pod can receive `SIGTERM` before it
leaves Traefik's endpoints, dropping in-flight requests on rollout/scale-down.
Next's standalone server does drain in-flight requests, and readiness gating
limits the window, so impact is small.

**Constraint:** distroless has **no shell**, so the usual
`preStop: exec [sleep]` will not work — would need a `sleep` binary in the image
or accept the race. Recommend leaving as-is unless 502s appear during deploys.

### 5. [Info] Probe target reality vs. the design doc

**Evidence:** `arunanshu.dev/docs/specs/k8s-pipeline-design.md` states
`/favicon.ico` is served "directly from `public/` without touching the RSC
renderer." It is actually `app/favicon.ico` (App Router metadata convention),
served by Next from the standalone build.

**Assessment:** probes still get 200, so they work — but it *is* Next-handled,
not a static `public/` file, so the "doesn't touch the renderer" rationale is
inaccurate. The design doc already lists a dedicated `/healthz` route handler as
future work; that remains the cleaner readiness signal.

### 6. [Info/cosmetic] Doc/label drift on base image

**Evidence:** the Dockerfile runtime-notes block and
`k8s-pipeline-design.md` still reference `distroless/nodejs24-debian12`; the
actual final `FROM` is `nodejs26-debian13`. Harmless; clean up when touching
those files.

---

## Remediation status

| # | Finding | Grade | Status |
|---|---------|-------|--------|
| 1 | Stable Server Actions encryption key | Medium | Open — needs key-placement decision |
| 2 | `MALLOC_ARENA_MAX=2` for glibc+sharp | Medium | Open |
| 3 | Shared cache handler (multi-pod) | Low/Info | Deferred — not needed until runtime data / on-demand revalidation |
| 4 | `preStop` graceful drain | Low | Deferred — distroless has no shell; revisit if deploy-time 502s appear |
| 5 | Probe target / `/healthz` route | Info | Open (future) |
| 6 | Base-image doc drift | Info | Open (cosmetic) |

## Method notes (for future passes)

- Ground Next.js claims in `node_modules/next/dist/docs/` and
  `config-shared.d.ts` of the **installed** version, per `arunanshu.dev/AGENTS.md`
  ("This is NOT the Next.js you know"). Online docs lag the preview build.
- `pnpm install --frozen-lockfile --ignore-scripts` in the app repo is enough to
  pull the bundled docs and type defs for grounding.
