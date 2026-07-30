# Make arunanshu.dev safe for multi-replica builds and streamed requests

> Status: Approved for implementation
>
> Date: 2026-07-31
>
> Content type: Reference
>
> Repositories: `arunanshub/arunanshu.dev` and `arunanshub/devops`

This specification defines the remaining changes from the Next.js self-hosting audit. It adds one stable Server Functions encryption key to production builds. It also gives Traefik more time to drain active requests. It does not add new application routes, response buffering, response time-outs, or HTTP/3 at Traefik.

## Goal for safe rolling deployments

Make rolling deployments safe for Server Functions and active streamed responses. Keep the current Cloudflare Tunnel, Traefik Gateway API, and Next.js standalone design.

The implementation must meet these outcomes:

- All production builds use the same Server Functions encryption key
- A missing production key stops the image build
- An invalid production key stops the release job
- The key does not appear in Docker arguments, image history, provenance, or workflow logs
- A key rotation invalidates the Next.js build cache
- The application continues to accept requests for 5s before `SIGTERM`
- Next.js then has up to 55s to finish active requests
- Kubernetes keeps each application process alive for 60s
- Next.js keeps idle backend connections open longer than Traefik
- Traefik accepts requests for 5s after `SIGTERM`
- Traefik then gives active requests 50s to finish
- Kubernetes keeps the Traefik process alive for 60s
- Existing Next.js streaming and compression behavior does not change

## Current architecture

Public traffic uses this path:

```text
client
  -> Cloudflare edge
  -> cloudflared
  -> Traefik web entry point
  -> Kubernetes Service
  -> Next.js standalone server
```

Cloudflare terminates public Transport Layer Security (TLS), HTTP/2, and HTTP/3. The tunnel sends HTTP/1.1 requests to Traefik. Traefik can accept HTTP/2 directly, but the public application path does not use that mode.

The Next.js application has these relevant properties:

- Next.js version is `16.3.0-preview.10`
- The image uses `output: 'standalone'`
- The workload runs at least two replicas
- Kubernetes Event-driven Autoscaling (KEDA) can increase the replica count
- Rolling deployments run old and new images at the same time
- `deploymentId` uses the build Git commit
- The repository contains a Server Action in `components/client-side-data-fetching/actions.ts`
- Production builds do not set `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY`
- The pod has no `preStop` handler
- The pod uses the Kubernetes default 30s termination period
- Next.js has built-in graceful handling for `SIGINT` and `SIGTERM`
- The standalone server uses the Node.js default 5s keep-alive timeout

The Traefik deployment has these relevant properties:

- Traefik version is `v3.7.9`
- Helm chart version is `41.1.0`
- The live deployment has two ready replicas
- Kubernetes gives each Traefik pod 60s to terminate
- `requestAcceptGraceTimeout` is `5s`
- `graceTimeOut` uses the Traefik default of `10s`
- The app route has compression but has no response buffering middleware
- The response write time-out is `0s`, which means no time limit

The live cluster uses K3s `v1.36.2+k3s1`. Its kubeconfig is `infra/kubeconfig.yaml` in the infrastructure repository. All live commands in this specification must use that file. Do not use the default `kubectl` context.

Live verification on 2026-07-31 found:

- The application, Traefik, and cloudflared Deployments were `Available`
- Each Deployment had two ready pods and zero pod restarts
- The related Argo CD Applications were `Synced` and `Healthy`
- The Traefik Gateway was `Accepted` and `Programmed`
- The application HTTPRoute was `Accepted` and had resolved references
- The public home page returned HTTP `200`
- The two current application pods had no `Failed to find Server Action` log entry in the previous 24 hours
- The two current Traefik pods had no error or fatal log entry in the previous four hours

The current pods use one image. The absence of current Server Action errors does not remove the mixed-build rollout risk.

Live inspection of the standalone Node.js server found:

```text
keepAliveTimeout = 5000ms
```

Traefik has no backend `ServersTransport` override. It uses the 90s default backend idle-connection timeout.

## Verified problems

### Production builds use different encryption keys

Next.js generates a new Server Functions encryption key for each build. One image shares its embedded key across all replicas of that image. A rolling deployment still runs two different builds together. The old and new builds can therefore use different keys.

Next.js requires one shared key for a multi-server deployment. A server can otherwise fail to decrypt closure data from another server. The documented error is `Failed to find Server Action`.

An earlier load investigation observed `Failed to find Server Action` errors from this application. That incident also contained other application errors. It does not prove that every error came from key mismatch. It does prove that the failure exists in this workload.

`deploymentId` does not replace the encryption key. The two controls solve different problems:

| Control                              | Purpose                                                                     |
| ------------------------------------ | --------------------------------------------------------------------------- |
| `deploymentId`                       | Detect client and server version skew, then use a full navigation           |
| `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` | Encrypt and decrypt Server Function closure data across builds and replicas |

Next.js documents both controls in separate multi-server sections. See the [Next.js self-hosting guide](https://nextjs.org/docs/app/guides/self-hosting#multi-server-deployments).

### Traefik has a short active-request drain period

The current Traefik configuration accepts requests for 5s after `SIGTERM`. It then uses the default 10s active-request grace period.

Live Traefik logs contained stream requests with durations from 24s to 44s. The clients ended those requests. Traefik did not end them.

A Traefik pod restart can stop the same type of request after the 10s default grace period. The other Traefik replica remains available, but that fact does not preserve the active connection.

### The application pod has a shorter drain period

Next.js stops accepting new connections after it receives `SIGTERM`. It then finishes active requests before it exits. The installed Next.js self-hosting guide recommends a configurable 10s to 30s drain period.

Kubernetes starts endpoint removal and container termination at the same time. A short interval can occur before all routing components stop selecting the terminating pod. The current pod has no `preStop` handler to cover this interval.

The current 30s pod termination period is also shorter than the observed 44s stream duration. Kubernetes can send `SIGKILL` before Next.js finishes such a request.

### Next.js closes idle backend connections before Traefik

The standalone Next.js server uses the Node.js default 5s keep-alive timeout. Traefik can retain the same idle backend connection for 90s.

Next.js recommends that its keep-alive timeout is longer than the downstream proxy timeout. This order prevents a connection-reuse race when the origin closes a connection that the proxy still holds.

No Traefik `5xx` response occurred during the checked 24-hour period. Treat this change as preventive. Do not attribute an observed incident to this mismatch without matching logs.

## Requirements for the key and request drain

### Server Functions key requirements

The production key must meet these rules:

- Generate 32 random bytes
- Encode the bytes with base64
- Store the value as a GitHub Actions repository secret
- Use the name `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY`
- Use the same value for every production build
- Supply the value only to the `next build` process
- Do not use a Docker `ARG` or persistent `ENV` for the value
- Do not write the value to a repository file
- Do not add the value to a Kubernetes Secret
- Do not print the value or its decoded bytes

Next.js embeds the build-time key in the server build output. The runtime image therefore does not need a separate environment variable.

### Build cache requirements

BuildKit does not include secret contents in a build cache checksum. A key rotation can reuse a cached `next build` layer unless another cache input changes.

Both application Dockerfiles must define a non-secret key version. The `next build` instruction must consume that version. A rotation must increase the version in the same change that updates the GitHub secret.

Use this name:

```text
SERVER_ACTIONS_KEY_VERSION
```

Start with value `1`.

### Traefik shutdown requirements

Use this shutdown budget:

| Phase                        | Duration | Purpose                                                    |
| ---------------------------- | -------: | ---------------------------------------------------------- |
| Accept grace                 |       5s | Give the Service and tunnel time to stop selecting the pod |
| Active request grace         |      50s | Let active requests finish                                 |
| Clearance before `SIGKILL`   |       5s | Let Traefik exit after its grace period                    |
| Kubernetes termination limit |      60s | Stop a process that does not exit                          |

The sum of the first two phases is 55s. This leaves 5s before Kubernetes sends `SIGKILL`.

Long-lived Server-Sent Events (SSE) and WebSocket clients must reconnect after a pod restart. No finite termination period can preserve an indefinite connection.

### Application shutdown requirements

Use this shutdown budget:

| Phase                        |  Duration | Purpose                                          |
| ---------------------------- | --------: | ------------------------------------------------ |
| Native `preStop` sleep       |        5s | Let endpoint updates reach routing components    |
| Next.js request drain        | up to 55s | Finish requests after Next.js receives `SIGTERM` |
| Kubernetes termination limit |       60s | Stop a process that does not exit                |

Kubernetes counts the `preStop` handler in the pod termination period. It sends `SIGTERM` after the handler completes. The 5s handler therefore leaves up to 55s for Next.js.

### Backend keep-alive requirement

Set the standalone Next.js server keep-alive timeout to 95s:

```text
KEEP_ALIVE_TIMEOUT=95000
```

Traefik closes an idle backend connection after 90s. The additional 5s makes Traefik close the connection first.

Do not change the Traefik backend transport timeout. The 90s default is suitable, and a Next.js environment setting is sufficient.

## Files and settings to change

### Changes in arunanshu.dev

| File                                | Change                                                        |
| ----------------------------------- | ------------------------------------------------------------- |
| `.github/workflows/release.yml`     | Validate the repository secret and pass it to BuildKit        |
| `Dockerfile`                        | Mount the secret for `pnpm build` and consume the key version |
| `Dockerfile.bun`                    | Fix its lockfile input and apply the same build contract      |
| `justfile`                          | Require and forward the secret for local image builds         |
| `docs/specs/k8s-pipeline-design.md` | Document the key, cache version, rotation, and first rollout  |

### Changes in arunanshu-infrastructure

| File                                                           | Change                                                           |
| -------------------------------------------------------------- | ---------------------------------------------------------------- |
| `kubernetes/base/platform/traefik/values.yaml`                 | Set `graceTimeOut: "50s"` and correct the lifecycle comment      |
| `tools/traefik/test-config.sh`                                 | Verify the rendered accept, request, and pod termination periods |
| `kubernetes/base/apps/arunanshu-dev/resources/deployment.yaml` | Add the application shutdown settings and 95s keep-alive timeout |
| `tools/loadtest/test-autoscaling-config.sh`                    | Verify the rendered application runtime settings                 |

### External change

Create this GitHub Actions repository secret:

```text
Repository: arunanshub/arunanshu.dev
Secret: NEXT_SERVER_ACTIONS_ENCRYPTION_KEY
Value: base64 encoding of 32 random bytes
```

The current repository secret list is empty. Create the secret before the workflow change reaches `master`.

### Why each file must change

| File or setting                 | Reason                                             | Failure when omitted                                                         |
| ------------------------------- | -------------------------------------------------- | ---------------------------------------------------------------------------- |
| GitHub repository secret        | Keep one key across production builds              | Each build generates a different key                                         |
| `.github/workflows/release.yml` | Validate and supply the secret                     | The production builder cannot read the key                                   |
| `Dockerfile`                    | Limit key access to `next build`                   | The key is absent or persists in Docker metadata                             |
| `Dockerfile.bun`                | Keep the alternate image contract equal            | Its absent lockfile input stops builds, or it can reintroduce per-build keys |
| `justfile`                      | Preserve local image builds after a required mount | The existing recipe fails without guidance                                   |
| Application pipeline document   | Record operation and rotation rules                | A later change can remove or rotate the key incorrectly                      |
| Traefik Helm values             | Increase active-request drain time                 | A restart can end streams after the 10s default                              |
| Traefik render test             | Enforce the complete shutdown budget               | A chart update can silently change a required period                         |
| Application Deployment          | Give endpoint updates and Next.js time to drain    | A rollout can send traffic to a stopping pod or end a stream                 |
| Application render test         | Enforce the application shutdown budget            | A later manifest change can remove the drain settings                        |
| `KEEP_ALIVE_TIMEOUT`            | Make Traefik close idle backend connections first  | A connection-reuse race can occur after Next.js closes first                 |

## Application repository design

### Create the repository secret

Generate and set the key without a plaintext file:

```bash
openssl rand -base64 32 \
  | tr -d '\n' \
  | gh secret set NEXT_SERVER_ACTIONS_ENCRYPTION_KEY \
      --repo arunanshub/arunanshu.dev
```

The command must not print the key. GitHub does not permit later reads of the secret value.

Verify only the secret name and update time:

```bash
gh secret list --repo arunanshub/arunanshu.dev
```

Do not create a GitHub Actions variable with the key. Do not put the key in an Actions cache.

### Pass the key to BuildKit

Add a validation step before `Build and push`:

```yaml
- name: Validate Server Functions encryption key
  env:
    KEY: ${{ secrets.NEXT_SERVER_ACTIONS_ENCRYPTION_KEY }}
  run: |
    node <<'NODE'
    const value = process.env.KEY ?? ''
    const decoded = Buffer.from(value, 'base64')
    if (decoded.length !== 32 || decoded.toString('base64') !== value) {
      console.error('NEXT_SERVER_ACTIONS_ENCRYPTION_KEY must contain 32 base64-encoded bytes')
      process.exit(1)
    }
    NODE
```

This step does not print the key. It rejects a missing key, invalid base64, and every decoded length other than 32 bytes.

Update the `Build and push` step:

```yaml
secrets: |
  "NEXT_SERVER_ACTIONS_ENCRYPTION_KEY=${{ secrets.NEXT_SERVER_ACTIONS_ENCRYPTION_KEY }}"
```

Keep `DEPLOYMENT_ID` as a build argument. It is not secret data.

Do not pass `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` through `build-args`. Docker warns that build arguments can appear in image history and provenance.

The Docker action uses a temporary secret file as the BuildKit source. See [Docker build secrets in GitHub Actions](https://docs.docker.com/build/ci/github-actions/secrets/).

### Mount the key for the Next.js build

Add the key version before the build instruction in `Dockerfile`:

```dockerfile
ARG SERVER_ACTIONS_KEY_VERSION=1
```

Replace the current build instruction with this contract:

```dockerfile
RUN --mount=type=cache,target=/app/.next/cache \
    --mount=type=secret,id=NEXT_SERVER_ACTIONS_ENCRYPTION_KEY,required=true,env=NEXT_SERVER_ACTIONS_ENCRYPTION_KEY \
    SERVER_ACTIONS_KEY_VERSION="${SERVER_ACTIONS_KEY_VERSION}" \
    sh -c 'test -n "${NEXT_SERVER_ACTIONS_ENCRYPTION_KEY}" && pnpm build'
```

The secret mount exists only for this `RUN` instruction. The `required=true` option stops the image build when the mount is absent. The `test` also stops the build when the mounted value is empty.

The non-secret version is visible to the build process. Next.js ignores it. BuildKit includes its value in the cache key for the build instruction.

Apply the same pattern to `Dockerfile.bun`. Add this syntax directive at the top because environment-backed secret mounts require a current Dockerfile frontend:

```dockerfile
# syntax=docker/dockerfile:1
```

The repository uses `pnpm-lock.yaml` and has no `bun.lock`. Replace the invalid lockfile copy:

```dockerfile
COPY package.json pnpm-lock.yaml ./
```

Bun automatically migrates the pnpm lockfile during `bun install`. With Bun 1.4, `--frozen-lockfile` performs this migration without changing `pnpm-lock.yaml` or writing a new lockfile.

Use this final command in that file:

```dockerfile
sh -c 'test -n "${NEXT_SERVER_ACTIONS_ENCRYPTION_KEY}" && bun run -b build'
```

The current `oven/bun:slim` image provides Bun 1.3.14. During verification, Bun completed the Next.js compile, type check, and static page generation. It then crashed with `SIGILL`. `Dockerfile.bun` has no release or local caller, so this upstream Bun failure does not block the production Node.js image.

Keep `Dockerfile.bun` for the Bun 1.4 release. When the stable image provides Bun 1.4:

1. Repeat the complete Bun image build
2. Verify the embedded Server Functions key
3. Verify that Docker history does not contain the key
4. Record the result in this specification

Do not add the Bun image to the release workflow until this build passes.

Docker documents the `env` and `required` mount options in the [Dockerfile secret mount reference](https://docs.docker.com/reference/dockerfile#run---mounttypesecret).

### Keep local image builds explicit

The primary Dockerfile will reject a build without the secret. Update the `docker-build` recipe in `justfile`.

The recipe must:

- Fail when `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` is empty
- Pass the value with Docker `--secret`
- Keep `DEPLOYMENT_ID` as the Git commit
- Never generate a production key
- Never print the key

Replace the recipe with:

```just
docker-build:
    @test -n "${NEXT_SERVER_ACTIONS_ENCRYPTION_KEY:-}" || { \
        echo "NEXT_SERVER_ACTIONS_ENCRYPTION_KEY is required" >&2; \
        exit 1; \
    }
    DOCKER_BUILDKIT=1 docker build \
        --secret id=NEXT_SERVER_ACTIONS_ENCRYPTION_KEY,env=NEXT_SERVER_ACTIONS_ENCRYPTION_KEY \
        --build-arg DEPLOYMENT_ID={{tag}} \
        -t {{image}}:{{tag}} \
        -t {{image}}:latest \
        .
```

Use this interface:

```bash
NEXT_SERVER_ACTIONS_ENCRYPTION_KEY=base64_key_here just docker-build
```

The operator can use a temporary 32-byte key for a local image. A local key must not replace the production GitHub secret.

### Update the pipeline document

Update `docs/specs/k8s-pipeline-design.md` in the application repository.

Record these facts:

- The release job supplies the shared key as a BuildKit secret
- Next.js embeds the key during `next build`
- All production builds use one stable key
- `deploymentId` remains a separate version-skew control
- `SERVER_ACTIONS_KEY_VERSION` invalidates the build cache during rotation
- The first secret-backed rollout has one mixed-key window
- Future rotations also have one mixed-key window
- Rotation requires a client refresh and a low-traffic rollout
- The current runtime base is Node.js 26, not Node.js 24

Do not add the secret value, a hash of the secret, or generated key material to the document.

## Infrastructure repository design

### Add an application runtime test first

Extend `tools/loadtest/test-autoscaling-config.sh`. This script already renders the application resources and selects the application Deployment. Reuse that render instead of adding a second test script.

Add exact assertions for:

```bash
app_deployment="$(
  yq 'select(.kind == "Deployment" and .metadata.name == "arunanshu-dev")' \
    - <<<"${rendered}"
)"
termination_grace="$(
  yq -r '.spec.template.spec.terminationGracePeriodSeconds' \
    - <<<"${app_deployment}"
)"
pre_stop_sleep="$(
  yq -r '.spec.template.spec.containers[] |
    select(.name == "arunanshu-dev") |
    .lifecycle.preStop.sleep.seconds' \
    - <<<"${app_deployment}"
)"
keep_alive_timeout="$(
  yq -r '.spec.template.spec.containers[] |
    select(.name == "arunanshu-dev") |
    .env[] |
    select(.name == "KEEP_ALIVE_TIMEOUT") |
    .value' \
    - <<<"${app_deployment}"
)"

[[ "${termination_grace}" == "60" ]]
[[ "${pre_stop_sleep}" == "5" ]]
[[ "${keep_alive_timeout}" == "95000" ]]
```

The first test run must fail. The current Deployment does not contain these fields.

### Give the application time to drain and align keep-alive

Update `kubernetes/base/apps/arunanshu-dev/resources/deployment.yaml`.

Add this field under `spec.template.spec`:

```yaml
terminationGracePeriodSeconds: 60
```

Add this field to the `arunanshu-dev` container:

```yaml
lifecycle:
  preStop:
    sleep:
      seconds: 5
```

Add this environment variable to the same container:

```yaml
- name: KEEP_ALIVE_TIMEOUT
  value: "95000"
```

Use the native Kubernetes sleep action. Do not use an `exec` action. The distroless image has no shell.

Do not set `NEXT_MANUAL_SIG_HANDLE`. The standalone Next.js server already handles `SIGINT` and `SIGTERM`. A manual handler would replace the built-in handler and could stop graceful request draining.

The generated standalone `server.js` reads `KEEP_ALIVE_TIMEOUT`. Do not add a custom server or change the application start command.

### Extend the Traefik render test first

Update `tools/traefik/test-config.sh` before the Helm values file.

The test must extract the rendered Traefik Deployment and verify:

```text
terminationGracePeriodSeconds = 60
requestAcceptGraceTimeout = 5s
graceTimeOut = 50s
```

The first test run must fail because the current render has no explicit `graceTimeOut` argument.

Check exact command-line arguments. Do not use a broad substring that can accept the wrong entry point.

Expected arguments:

```text
--entryPoints.web.transport.lifeCycle.requestAcceptGraceTimeout=5s
--entryPoints.web.transport.lifeCycle.graceTimeOut=50s
```

The test must continue to use chart version `41.1.0` from the Argo CD Application.

### Increase the active-request grace period

Update the `ports.web.transport.lifeCycle` section in `kubernetes/base/platform/traefik/values.yaml`:

```yaml
ports:
  web:
    transport:
      lifeCycle:
        requestAcceptGraceTimeout: "5s"
        graceTimeOut: "50s"
```

Correct the nearby comment. The 5s phase does not drain requests. It gives downstream routing components time to stop selecting the pod. The 50s phase drains requests that are active after the accept phase.

Do not set `deployment.terminationGracePeriodSeconds`. Chart `41.1.0` already renders `60`. The render test will make that chart default an enforced invariant.

## Rollout order

Use this order to avoid a release failure and reduce connection loss:

1. Create `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` in the application repository
2. Verify the secret name with `gh secret list`
3. Add the failing application runtime assertions
4. Add the failing Traefik render assertion
5. Add the application shutdown and keep-alive settings
6. Set Traefik `graceTimeOut` to `50s`
7. Run all infrastructure checks
8. Merge and deploy the infrastructure change
9. Confirm the application and Traefik Deployments complete their updates
10. Update the application workflow, Dockerfiles, recipe, and pipeline document
11. Run all application checks with a non-production test key
12. Merge the application change during a low-traffic period
13. Confirm the release job builds and pushes a new image
14. Review the Renovate image update in the infrastructure repository
15. Merge the image update
16. Watch the Next.js rolling deployment until all old pods stop
17. Confirm that application errors return to the baseline

The first secret-backed image will overlap with an image that contains an older generated key. This first rollout can still produce Server Action errors. The stable key protects all later builds.

## Validate builds and rollouts

### Application checks before merge

Run the existing checks:

```bash
pnpm exec tsc --noEmit
pnpm lint
NEXT_SERVER_ACTIONS_ENCRYPTION_KEY="$(openssl rand -base64 32 | tr -d '\n')" \
  pnpm build
```

The direct `pnpm build` check uses a generated development key. It does not create a production artifact or change the production secret.

Build the primary image with a non-production test key:

```bash
export NEXT_SERVER_ACTIONS_ENCRYPTION_KEY
NEXT_SERVER_ACTIONS_ENCRYPTION_KEY="$(openssl rand -base64 32)"
just docker-build
```

Build the alternate Bun image with the same test interface after the stable image provides Bun 1.4:

```bash
docker build \
  --file Dockerfile.bun \
  --secret id=NEXT_SERVER_ACTIONS_ENCRYPTION_KEY,env=NEXT_SERVER_ACTIONS_ENCRYPTION_KEY \
  --build-arg DEPLOYMENT_ID=test \
  --tag arunanshu-dev:bun-test \
  .
```

Verify that the test key does not appear in image history:

```bash
if docker history --no-trunc arunanshu-dev:bun-test \
  | grep --fixed-strings --quiet "${NEXT_SERVER_ACTIONS_ENCRYPTION_KEY}"; then
  exit 1
fi
```

Do not print the manifest encryption key. Compare values inside a local check and print only pass or fail.

Build twice with the same test key and different deployment IDs. Use `docker create` and `docker cp` to read `/app/.next/server/server-reference-manifest.json` from each image without starting it. Compare the `.encryptionKey` fields in memory. Remove the stopped containers and temporary manifest files. Verify that:

- Each field is a 44-character canonical base64 string
- Each field decodes to 32 bytes
- Both fields equal the supplied test key
- Both fields equal each other

Then increase `SERVER_ACTIONS_KEY_VERSION` in a temporary patch and use a different test key. Verify that the build does not reuse the old build layer. Restore the version before commit.

### Infrastructure checks before merge

Run the focused Traefik test:

```bash
devbox run -- tools/traefik/test-config.sh
```

Run the application render test:

```bash
devbox run -- bash tools/loadtest/test-autoscaling-config.sh
```

Render the production overlay:

```bash
devbox run -- kustomize build kubernetes/overlays/prod
```

Validate the rendered resources with the same kubeconform command as continuous integration (CI):

```bash
devbox run -- kustomize build kubernetes/overlays/prod \
  | devbox run -- kubeconform \
      --strict \
      --ignore-missing-schemas \
      --summary \
      --schema-location default \
      --schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Run repository hygiene checks that cover the changed files:

```bash
devbox run -- yamlfmt -lint
devbox run -- shellcheck --enable=all --severity=style \
  tools/traefik/test-config.sh
```

### Live Traefik checks

From the infrastructure repository, select the correct cluster:

```bash
export KUBECONFIG="$PWD/infra/kubeconfig.yaml"
kubectl config current-context
kubectl cluster-info
```

The control-plane address must be `https://[2a01:4f9:c014:e7f9::1]:6443`. Stop if the command requests AWS credentials or shows a different control plane.

After Argo CD syncs the Traefik change, verify:

- Argo CD reports `Synced` and `Healthy`
- The Deployment has two ready and available replicas
- Both pods have zero new restarts
- The pod termination period is 60s
- The application pod has `KEEP_ALIVE_TIMEOUT=95000`
- The web entry point has both lifecycle arguments
- The Gateway and application HTTPRoute remain accepted
- A request through the Traefik Service returns `200`
- A long stream remains active past 10s
- A controlled Traefik pod restart does not produce an error spike

Do not restart both Traefik pods together.

### Live application checks

After the image update reaches the cluster, verify:

- The Deployment completes its rolling update
- All ready pods use the same image digest
- The home page returns `200`
- A Server Action request returns `200`
- React Server Component (RSC) navigation succeeds across repeated requests
- The `Failed to find Server Action` error rate returns to zero after old clients expire
- Traefik does not show a related `5xx` increase
- Cloudflared keeps all expected tunnel connections

Do not treat the first mixed-key rollout as proof of failure. Check again after all old pods stop.

For the infrastructure rollout, start an existing long request before a controlled application pod deletion. Verify these events:

1. The terminating endpoint changes to `ready=false` and `terminating=true`
2. The application process continues for the 5s `preStop` interval
3. Next.js receives `SIGTERM` after the interval
4. The existing request finishes before the pod stops
5. New requests use a ready replacement pod

Do not delete more than one application pod. Do not add a test route for this check.

## Key rotation

Do not rotate the key during a normal dependency update.

Rotate it when:

- The key can be read by an unauthorized person
- Repository administration or build-system compromise can expose it
- A policy requires rotation

Use this rotation sequence:

1. Choose a low-traffic period
2. Increase `SERVER_ACTIONS_KEY_VERSION` in both Dockerfiles
3. Update `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` with a new 32-byte value
4. Merge a new application build
5. Deploy the new image
6. Expect stale clients to refresh
7. Monitor Server Action errors until old clients expire

Next.js accepts one active key. It has no documented dual-key rotation period. A rotation therefore creates one mixed-key deployment window.

If the key version does not change, use a no-cache image build. Do not rely on this manual exception as the normal process.

## Roll back each repository

### Roll back the Traefik change

Revert the infrastructure implementation commit. Argo CD will restore the 10s default `graceTimeOut`.

The rollback reduces drain time. It does not change routing, ports, middleware, or public protocols.

The same revert removes the application `preStop` sleep and restores the default 30s pod termination period. This can stop active requests sooner.

### Roll back the application change

Select the previous image tag in the infrastructure repository. Argo CD will restore the previous image.

Keep the GitHub secret during investigation. Deleting it will make the updated release workflow fail before the image build.

A rollback to an image with its old generated key can invalidate Server Action closure data from the new image. Clients must refresh.

## Security limits

The encryption key protects Server Function closure data in transit through the client. It is not an authorization control.

The built server output contains the key because Next.js embeds it. A person who can read the container image can extract it. Repository and package access must therefore remain controlled.

The current GitHub token cannot read package visibility because it lacks the `read:packages` scope. An anonymous request to the package page returns `404`, which can mean that the package is private or absent. An authorized repository administrator must verify the package visibility. Until that check is complete, apply the security controls required for a public image. This check does not block implementation.

Application code must still:

- Authenticate each sensitive Server Action
- Authorize the requested operation
- Validate all action input
- Avoid captured secrets in inline Server Action closures, for public and private images

The current Server Action captures no sensitive value. It accepts a delay and a display name.

## Explicit non-changes

The implementation must not make these changes:

- Do not add `/healthz`
- Do not add a synthetic streaming route
- Do not add `X-Accel-Buffering`
- Do not set `responseForwarding.flushInterval`
- Do not add the Traefik buffering middleware
- Do not set a Traefik response write time-out
- Do not change the 60s request read time-out
- Do not remove response compression
- Do not compress `text/event-stream`
- Do not enable HTTP/3 at Traefik
- Do not change the Cloudflare Tunnel protocol
- Do not add a Kubernetes Secret for the Server Functions key
- Do not add the key to `env.ts`
- Do not add the key to `next.config.ts`
- Do not change `deploymentId`
- Do not set `NEXT_MANUAL_SIG_HANDLE`
- Do not add a custom Next.js server
- Do not change the Traefik 90s backend idle-connection timeout
- Do not use an `exec` lifecycle hook in the distroless application image
- Do not add a shared cache in this change

These changes do not fix the two verified problems. Some can also stop valid streams or add a new public surface.

The cached pages use content from the built application image. The application does not call `revalidateTag`, `revalidatePath`, `cacheTag`, or `updateTag`. A remote shared cache would therefore add a service without fixing a current consistency failure.

## Acceptance criteria

The work is complete when all these statements are true:

- GitHub lists `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` for `arunanshub/arunanshu.dev`
- The production Docker build fails when the secret is missing
- The release validation rejects a missing, malformed, or wrong-length key
- Both Dockerfiles mount the key only for the build instruction
- Both Dockerfiles consume `SERVER_ACTIONS_KEY_VERSION`
- The Bun dependency stage reads the tracked `pnpm-lock.yaml`
- Bun 1.4 completes the alternate image build before that image gets a release caller
- Docker history does not contain the supplied test key
- Two builds with one key embed the same manifest key
- A key version increase invalidates the build layer
- The application documentation explains first rollout and rotation behavior
- The application render test fails before the termination settings change
- The application render test passes after the termination settings change
- The rendered application `preStop` sleep is 5s
- The rendered application termination period is 60s
- The rendered `KEEP_ALIVE_TIMEOUT` value is `95000`
- The Traefik render test fails before the values change
- The Traefik render test passes after the values change
- The rendered pod termination period is 60s
- The rendered accept grace period is 5s
- The rendered active-request grace period is 50s
- Kustomize and kubeconform checks pass
- Both Traefik replicas return to ready state after rollout
- The application rolling deployment completes
- Server Action and RSC requests succeed after all old pods stop
- No new sustained Traefik, cloudflared, or application error spike remains

## Source documents

- [Next.js self-hosting and multi-server deployments](https://nextjs.org/docs/app/guides/self-hosting#multi-server-deployments)
- [Next.js Server Actions security](https://nextjs.org/docs/app/guides/data-security#overwriting-encryption-keys-advanced)
- [Next.js production server timeouts](https://nextjs.org/docs/app/api-reference/cli/next#configuring-timeout-values)
- [Docker build secrets](https://docs.docker.com/build/building/secrets/)
- [Dockerfile secret mounts](https://docs.docker.com/reference/dockerfile#run---mounttypesecret)
- [Docker secrets with GitHub Actions](https://docs.docker.com/build/ci/github-actions/secrets/)
- [Bun lockfile migration](https://bun.sh/docs/pm/lockfile#automatic-lockfile-migration)
- [GitHub Actions repository secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)
- [Kubernetes pod termination](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination-flow)
- [Kubernetes container lifecycle hooks](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/)
- [Traefik entry point lifecycle](https://doc.traefik.io/traefik/reference/install-configuration/entrypoints/)
- [Traefik response forwarding](https://doc.traefik.io/traefik/reference/routing-configuration/http/load-balancing/service/)
- [Traefik backend transport timeouts](https://doc.traefik.io/traefik/reference/routing-configuration/http/load-balancing/serverstransport/)
