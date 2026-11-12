# Kener Helm Chart

![Version: 2026.11.7](https://img.shields.io/badge/Version-2026.11.7-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 4.2.1](https://img.shields.io/badge/AppVersion-4.2.1-informational?style=flat-square)
[![UWOSC: maintained](https://helm.unxwares.studio/assets/uwosc/mini-maintained.svg)](https://helm.unxwares.studio/#open-source)

[Kener](https://kener.ing) is an open source status page: monitors (HTTP, TCP, DNS, ping, SSL, SQL, gRPC,
heartbeat...), incidents, maintenances and subscriptions. This chart, maintained by UnxWares, runs Kener 4 on
Kubernetes with the Redis it requires: a bundled single-instance Valkey by default, or your own Redis. Kener stores
its data in SQLite on a persistent volume, or in an external PostgreSQL or MySQL database.

## Features

- **Kener 4** on SQLite (single replica + PVC kept on uninstall), PostgreSQL or MySQL. Database migrations run
  automatically at startup.
- **Bundled Valkey** (Redis compatible, required by Kener 4 for its queues): a single hardened pod with a generated
  password, no persistence by default since Kener rebuilds its schedules from the database. Or bring your own
  Redis 6+ through `redis.external`.
- **No default credentials**: `KENER_SECRET_KEY` and the Valkey password are generated and kept across upgrades and
  reinstalls, or read from your own Secrets. The database URL, Redis URL, SMTP password, Resend key and proxy URLs
  only reach the container through `secretKeyRef`.
- **Hardened by default**: non-root (uid 1000), read-only root filesystem, every capability dropped, seccomp
  `RuntimeDefault`, no service account token. The default pods meet the Pod Security Standard `restricted`.
- **Image choice**: Alpine variant by default (far fewer known CVEs than the Debian one), Debian on demand, and the
  upstream `-status` images for a `/status` base path.
- **Probes on `/healthcheck`**: readiness uses `?strict=1`, so a pod leaves the Service while its database or Redis
  is unreachable.
- **Validation**: the chart refuses values that would give a broken or insecure deployment (origin with a path,
  public secret key, several replicas on SQLite, a PodDisruptionBudget that blocks node drains, missing Redis,
  incomplete SMTP settings...).
- Ingress or Gateway API HTTPRoute, optional NetworkPolicies (Valkey only reachable by Kener, without any egress),
  PodDisruptionBudget and HPA (SQL databases), `helm test`, and an end-to-end test in CI.

## Architecture

The names below are those of a release called `status`: resources are named `<release>-kener` (or just `<release>`
when the release name already contains `kener`, or `fullnameOverride`).

| Resource | Name | Created when | Role |
|----------|------|--------------|------|
| Deployment | `status-kener` | always | Kener (Node.js), container port `3000` (`http`). `replicaCount` replicas (1 with SQLite); `Recreate` strategy with SQLite on a PVC. |
| Service | `status-kener` | always | `service.type` (ClusterIP), port `service.port` (3000) to the container port 3000. |
| PersistentVolumeClaim | `status-kener` | SQLite, `persistence.enabled` and no `persistence.existingClaim` | SQLite database, mounted on `/app/database`. Annotated `helm.sh/resource-policy: keep`. |
| Deployment | `status-kener-valkey` | `redis.enabled` (default) | Valkey, 1 replica, `Recreate` strategy, container port `6379`. |
| Service | `status-kener-valkey` | `redis.enabled` | ClusterIP, port `redis.service.port` (6379). |
| ConfigMap | `status-kener-valkey` | `redis.enabled` | `valkey.conf` (no password inside). |
| PersistentVolumeClaim | `status-kener-valkey` | `redis.persistence.enabled` and no `redis.persistence.existingClaim` | Valkey append-only file, mounted on `/data`. Annotated `helm.sh/resource-policy: keep`. |
| Secret | `status-kener` | at least one value to store (always with the defaults) | Generated or given secrets (see [Secrets](#secrets-and-existing-secrets)). Annotated `helm.sh/resource-policy: keep`. |
| ServiceAccount | `status-kener` | `serviceAccount.create` (default) | Used by the Kener and Valkey pods, token not mounted, no RBAC. |
| Ingress | `status-kener` | `ingress.enabled` | Routes `ingress.hosts` to the Kener Service. |
| HTTPRoute | `status-kener` | `httpRoute.enabled` | Gateway API route to the Kener Service. |
| NetworkPolicy | `status-kener`, `status-kener-valkey` | `networkPolicy.enabled` | Ingress rules for Kener; ingress and egress rules for Valkey. |
| PodDisruptionBudget | `status-kener` | `podDisruptionBudget.enabled` (PostgreSQL/MySQL, 2+ replicas) | For the Kener pods. |
| HorizontalPodAutoscaler | `status-kener` | `autoscaling.enabled` | CPU (and optionally memory) based, PostgreSQL/MySQL only. |
| Pod | `status-kener-test-healthcheck` | `helm test` | See [Testing](#testing). |

Volumes:

- Kener: `/tmp` (emptyDir, 64Mi), and with SQLite `/app/database` (the PVC, or an emptyDir when
  `persistence.enabled` is false). Nothing is mounted on `/app/database` with PostgreSQL or MySQL. Kener 4 stores
  uploaded images (logo, favicon...) in the database.
- Valkey: `/etc/valkey` (the ConfigMap, read-only), `/data` (the PVC, or an emptyDir limited to 1Gi) and `/tmp`
  (emptyDir, 16Mi).

There is no init container, Job or CronJob: Kener runs its database migrations and seeds itself when it starts.
Inside the Kener container, each check of an API, Ping, TCP or GameDig monitor starts a short-lived Node.js process
for its eval code (see [Monitor eval code](#monitor-eval-code)).

## Images

| Component | Default image | Values |
|-----------|---------------|--------|
| Kener | `docker.io/rajnandan1/kener:4.2.1-alpine` | `image.*` |
| Valkey | `docker.io/valkey/valkey:9.1.3-alpine` | `redis.image.*` |

When `image.tag` is empty, the chart builds the Kener tag from the chart `appVersion`, `kener.basePath` and
`image.variant`, following the naming of the published images:

| `kener.basePath` | `image.variant: alpine` (default) | `image.variant: debian` |
|------------------|-----------------------------------|-------------------------|
| `""` (default) | `4.2.1-alpine` | `4.2.1` |
| `/status` | `4.2.1-status-alpine` | `4.2.1-status` |

The Alpine variant (on `node:24-alpine`) carries far fewer known vulnerabilities than the Debian one (on
`node:24-slim`, the upstream default). The base path is compiled into the image: any path other than `""` and
`/status` needs your own build of Kener (`KENER_BASE_PATH` build argument) in `image.tag` or `image.digest`. The
`helm test` pod uses the Kener image too, unless `tests.image` is set.

This chart has no `imageProvider` value: it runs the images published by the Kener and Valkey projects, and does not
use the UnxWares images (`ghcr.io/unxwares`, built from [images/](https://github.com/UnxWares/helm/tree/main/images)
for other charts). These images are published for `linux/amd64` and `linux/arm64`.

To pin an image by digest, set `image.digest` and `redis.image.digest`: the digest takes precedence over the tag and
the variant logic, so pin the digest of the tag that matches your `kener.basePath` (for example the
`4.2.1-status-alpine` one for `/status`). `redis.image.tag` has no hidden default: with the bundled Valkey, keep a
tag or set the digest, or the chart refuses to render. `docker buildx imagetools inspect docker.io/rajnandan1/kener:4.2.1-alpine`
prints the digest of a tag.

```yaml
image:
  digest: sha256:<digest of docker.io/rajnandan1/kener:4.2.1-alpine>
redis:
  image:
    digest: sha256:<digest of docker.io/valkey/valkey:9.1.3-alpine>
```

To pull from a mirror, change `image.repository` and `redis.image.repository` and list the pull secrets in
`imagePullSecrets` (used by every pod of the chart, the test pod included).

The [CVE watch](https://github.com/UnxWares/helm/issues?q=is%3Aissue+is%3Aopen+label%3Acve-watch) scans the default
images and those of the `ci/` values files (`4.2.1-status` included) every day; chart releases that only bump an
image for vulnerabilities are flagged `containsSecurityUpdates` on Artifact Hub.

## Requirements

Kubernetes: `>=1.27.0-0`

- **Storage**: with SQLite (the default), a `ReadWriteOnce` volume of 2Gi from the default StorageClass, or from
  `persistence.storageClass`. The bundled Valkey only needs one with `redis.persistence.enabled`.
- **Exposure**: an Ingress controller or a Gateway API implementation (`HTTPRoute` `gateway.networking.k8s.io/v1`)
  to publish the status page, or a `LoadBalancer`/`NodePort` Service.
- **Optional external services**: a PostgreSQL or MySQL database (Kener creates its tables), a Redis 6+ or Valkey
  server instead of the bundled one, an SMTP server or a [Resend](https://resend.com) account for email.
- **Nodes**: `linux/amd64` or `linux/arm64`.
- **Pod Security**: the default pods meet the `restricted` standard. `pingMonitors.enabled` adds `NET_RAW` to the
  container capabilities, which neither `restricted` nor `baseline` allow: the namespace must then enforce
  `privileged` (see [Ping monitors](#ping-monitors)).
- **NetworkPolicy**: `networkPolicy.enabled` only has an effect with a CNI that enforces NetworkPolicies.

## Installation

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
helm install status unxwares/kener --namespace status --create-namespace \
  --set kener.origin=https://status.example.com
```

Charts are signed with the UnxWares Helm Charts OpenPGP key (fingerprint
`7902 E52E A435 EF27 C643  2E53 78D6 B532 C599 DA9B`, public key
https://helm.unxwares.studio/pgp-public-key.asc). To check the signature at install time:

```bash
curl -fsSL https://helm.unxwares.studio/pgp-public-key.asc | gpg --import
gpg --export 7902E52EA435EF27C6432E5378D6B532C599DA9B > ~/.gnupg/unxwares-helm.gpg
helm install status unxwares/kener --namespace status --create-namespace \
  --set kener.origin=https://status.example.com \
  --verify --keyring ~/.gnupg/unxwares-helm.gpg
```

See [verifying signatures](https://github.com/UnxWares/helm/blob/main/SECURITY.md#verifying-chart-signatures) for
details.

The only value a real install needs is `kener.origin`:

```yaml
kener:
  origin: https://status.example.com
```

`kener.origin` must be the exact URL users type in their browser (scheme + host + optional port, no path, no
trailing slash): Kener rejects every form, login included, when it does not match. The default,
`http://localhost:3000`, only suits a quick test through a port-forward:

```bash
kubectl -n status rollout status deploy/status-kener
kubectl -n status port-forward svc/status-kener 3000:3000
```

Then open `<origin><basePath>/account/signin` (`http://localhost:3000/account/signin` for the port-forward) and
create the administrator account. Kener lets **anyone** who reaches this page create the first account while none
exists: do it before exposing the page publicly (through a port-forward, or with the Ingress restricted to your
network). To publish the page, see [Exposure](#exposure).

## Configuration

### Public URL and base path

| Value | Default | Effect |
|-------|---------|--------|
| `kener.origin` | `http://localhost:3000` | `ORIGIN`: public URL, validated (scheme + host + optional port). `https://` also turns on secure cookies. |
| `kener.basePath` | `""` | `KENER_BASE_PATH`: serve Kener under a sub path such as `/status`. Selects the `-status` image (see [Images](#images)). |
| `kener.bodySizeLimit` | `3M` | `BODY_SIZE_LIMIT`: maximum request body, raise it to upload larger images. |
| `kener.nodeEnv` | `production` | `NODE_ENV`. |

With a base path, keep it out of `kener.origin` and route that path in the Ingress or HTTPRoute (see
[Under /status with the Gateway API](#under-status-with-the-gateway-api)). Probes and the test pod follow the base
path (`<basePath>/healthcheck`).

### Persistence

With SQLite (no external database), the database lives in `/app/database/kener.sqlite.db`, on a PVC created by the
chart:

```yaml
persistence:
  enabled: true
  storageClass: fast-ssd
  size: 5Gi
  # or reuse an existing PVC instead (the chart then creates none):
  # existingClaim: kener-data
```

The PVC carries `helm.sh/resource-policy: keep`: `helm uninstall` leaves it in place. With
`persistence.enabled: false`, the database is in an emptyDir and lost with the pod (NOTES print a warning). Do not
mount anything on `/app/database` through `extraVolumeMounts`: the chart refuses it with SQLite, use
`persistence.existingClaim`. `fsGroup: 1000` makes the files of an existing volume accessible to Kener.

### Database

SQLite is the default: leave `database.url` and `database.existingSecret` empty. It supports a single Kener replica
(the chart refuses `replicaCount > 1` and `autoscaling.enabled` with it).

PostgreSQL or MySQL: give the URL, either as a value (the chart stores it in its Secret) or in your own Secret:

```yaml
database:
  url: postgresql://kener:s3cr3t@db-rw.databases.svc:5432/kener
  pool:
    max: 10
    workerMax: 5
```

```yaml
database:
  existingSecret: kener-database     # mysql://kener:<password>@mysql.databases.svc:3306/kener
  existingSecretKey: database-url
```

- Kener only accepts `postgresql://` (not `postgres://`) and `mysql://` URLs; the chart refuses `postgres://` and any
  other scheme in `database.url`. It cannot check a URL read from `database.existingSecret`.
- Percent-encode reserved characters of the password (`@` → `%40`, `/` → `%2F`, `:` → `%3A`...).
- The database must exist; Kener creates and migrates its tables at startup.
- `database.pool.*` and `database.keepAlive` set the `DATABASE_*` pool variables; left `null`, Kener uses its own
  defaults (10 web and 5 worker connections per replica). Keep
  `replicas × (DATABASE_POOL_MAX + DATABASE_WORKER_POOL_MAX)` below the database `max_connections`.
- `database.url` also accepts `sqlite://` URLs inside `/app/database` (for example
  `sqlite://./database/kener-restored.db`), which is how a restored copy is used (see
  [Backup and restore](#backup-and-restore)).

### Redis

Kener 4 needs Redis for its queues (BullMQ), cache and schedulers. By default the chart deploys a single Valkey pod
with a generated password; Kener reaches it at `redis://:$(REDIS_PASSWORD)@status-kener-valkey:6379`. The
`valkey.conf` it writes sets `maxmemory-policy noeviction` (BullMQ refuses any other policy) and, without
persistence, `save ""` and `appendonly no`: a restart of Valkey only loses queued jobs (pending notifications), since
Kener rebuilds its monitor schedules from the database.

```yaml
redis:
  persistence:
    enabled: true          # appendonly yes, appendfsync everysec, on a PVC
    size: 1Gi
  extraConfig: |
    maxmemory 200mb
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      memory: 256Mi
```

`redis.extraConfig` lines are appended to `valkey.conf`: keep `maxmemory-policy noeviction`. The Valkey password
(`redis.auth.password` or `redis.auth.existingSecret`) is embedded in `REDIS_URL`, so it is limited to
`A-Z a-z 0-9 . _ ~ -` (the chart checks `redis.auth.password`, not the content of an existing Secret).

Your own Redis 6+ or Valkey instead (the chart then deploys no Valkey):

```yaml
redis:
  enabled: false
  external:
    existingSecret: kener-redis      # key redis-url = rediss://default:<password>@redis.example.com:6379/0
    existingSecretKey: redis-url
```

`redis.external.url` takes the same URL as a value (`redis://`, or `rediss://` for TLS). The chart refuses
`redis.external.*` while `redis.enabled` is true, and `redis.enabled: false` without an external URL.

### Exposure

The Kener Service is `ClusterIP` on port 3000 by default. `service.port` only changes the Service port: the
container always listens on 3000.

```yaml
kener:
  origin: http://status.internal.example.com
service:
  type: LoadBalancer
  port: 80
```

Ingress: set `ingress.enabled`, `ingress.className`, `ingress.hosts` (each path goes to the Kener Service, `pathType`
defaults to `Prefix`) and `ingress.tls` (see
[Public status page behind an Ingress](#public-status-page-behind-an-ingress)).

Gateway API: set `httpRoute.enabled`, `httpRoute.parentRefs` (the default, `gateway`/`http`, is a placeholder),
`httpRoute.hostnames` and `httpRoute.rules`. Every rule is sent to the Kener Service; a rule can carry `matches` and
`filters` (see [Under /status with the Gateway API](#under-status-with-the-gateway-api)).

### TLS

The chart does not terminate TLS: do it in the Ingress controller or the Gateway (for example with cert-manager), and
set `kener.origin` to the `https://` URL, which also turns on secure cookies. Inside the cluster, Kener talks to the
bundled Valkey over the plain Redis protocol (password-protected, not encrypted). For an external Redis over TLS, use
a `rediss://` URL.

### Secrets and existing Secrets

The chart Secret `status-kener` holds only what is not read from your own Secrets:

| Key | Source value | Generated when empty | Your own Secret instead |
|-----|--------------|----------------------|-------------------------|
| `secret-key` | `kener.secretKey` | yes, 64 characters | `kener.existingSecret` + `kener.existingSecretKey` |
| `redis-password` | `redis.auth.password` | yes, 40 characters | `redis.auth.existingSecret` + `redis.auth.existingSecretPasswordKey` |
| `database-url` | `database.url` | no | `database.existingSecret` + `database.existingSecretKey` |
| `redis-url` | `redis.external.url` | no | `redis.external.existingSecret` + `redis.external.existingSecretKey` |
| `smtp-password` | `email.smtp.password` | no | `email.smtp.existingSecret` + `email.smtp.existingSecretPasswordKey` |
| `resend-api-key` | `email.resend.apiKey` | no | `email.resend.existingSecret` + `email.resend.existingSecretKey` |
| `http-proxy`, `https-proxy` | `proxy.httpProxy`, `proxy.httpsProxy` | no | `proxy.existingSecret` + `proxy.existingSecretHttpProxyKey`, `proxy.existingSecretHttpsProxyKey` |

Generated values are read back from the existing Secret at each `helm upgrade` (Helm `lookup`), so they stay the
same across upgrades. The Secret carries `helm.sh/resource-policy: keep`, like the PVCs: `helm uninstall` leaves it,
and a new install under the same release name and namespace reads it back too (see [Uninstalling](#uninstalling)).
`KENER_SECRET_KEY` signs sessions and hashes API keys: a new key logs everybody out **and invalidates every API
key**. The chart refuses the public keys `thesuperprivatekeytonotshare` (previous chart
default) and `DUMMY_SECRET`; NOTES warn about a `kener.secretKey` shorter than 32 characters.

**GitOps**: generated secrets cannot be read back by tools that render templates offline (Argo CD...), which would
rotate them on every sync. Use your own Secrets (or set `kener.secretKey` and `redis.auth.password`):

```yaml
kener:
  existingSecret: kener                  # key secret-key: 32+ random characters
  existingSecretKey: secret-key
redis:
  auth:
    existingSecret: kener                # key redis-password: A-Z a-z 0-9 . _ ~ - only
    existingSecretPasswordKey: redis-password
```

```bash
kubectl -n status create secret generic kener \
  --from-literal=secret-key="$(openssl rand -hex 32)" \
  --from-literal=redis-password="$(openssl rand -hex 20)"
```

Pods restart when a secret given as a value changes (checksum annotation), not when the content of your own Secret
changes: run `kubectl rollout restart` on both Deployments after rotating it.

### Authentication and SSO

Kener manages its users itself: the first account is created at `<origin><basePath>/account/signin` (see
[Installation](#installation)), the next ones are invited from the dashboard (invitations need [email](#email)).
OpenID Connect is configured in Kener (Manage, OIDC settings), not through the chart. If the identity provider is
down while the email/password login is disabled in these settings, re-enable it for a while:

```yaml
kener:
  forceLocalLogin: true    # KENER_FORCE_LOCAL_LOGIN, turn it off once the provider works again
```

### Email

Kener sends invitations, email verifications, password resets and subscriber notifications through SMTP or
[Resend](https://resend.com). SMTP wins when both are set.

```yaml
email:
  smtp:
    host: smtp.example.com
    port: 587
    user: status@example.com
    existingSecret: kener-smtp     # key: smtp-password
    fromEmail: Status <status@example.com>
```

`email.smtp.secure: true` selects implicit TLS (`SMTP_SECURE=1`, usually port 465); keep `false` for STARTTLS on
587. The chart refuses an SMTP host without port, user, sender and password, since Kener would ignore it.

```yaml
email:
  resend:
    existingSecret: kener-resend   # key: resend-api-key
    senderEmail: Status <status@example.com>
```

### Outbound proxy

Monitors, triggers, Resend and OIDC calls can go through an HTTP proxy. `HTTP_PROXY` and `HTTPS_PROXY` reach the
container through the chart Secret (they may carry credentials, percent-encoded):

```yaml
proxy:
  httpProxy: http://proxy.example.com:3128
  httpsProxy: http://proxy.example.com:3128
  noProxy: localhost,127.0.0.1,.svc,.cluster.local
```

Or keep the URLs in your own Secret (`proxy.httpProxy` and `proxy.httpsProxy` are then ignored; either key may be
missing, the variable is then left unset):

```yaml
proxy:
  existingSecret: kener-proxy     # keys http-proxy and https-proxy
  noProxy: localhost,127.0.0.1,.svc,.cluster.local
```

`NO_PROXY` takes hosts, `host:port` and `.suffix` entries, not CIDRs: add the in-cluster services your monitors reach
directly.

### Secrets for monitors and triggers

Kener replaces `$NAME` in monitor URLs, headers, bodies, SQL connection strings and trigger settings with the
environment variable `NAME`. Pass them from a Secret, never as plain values:

```yaml
extraEnv:
  - name: API_TOKEN
    valueFrom:
      secretKeyRef:
        name: kener-monitor-secrets
        key: api-token
extraEnvFrom:
  - secretRef:
      name: kener-monitor-secrets   # API_TOKEN, DB_PASSWORD...
```

Kener substitutes **any** variable of its environment, including `KENER_SECRET_KEY`, `DATABASE_URL` and
`REDIS_URL`: a user allowed to edit monitors or triggers can send them to a server of their choice. Only give these
permissions to people you would trust with the secrets themselves.

### Ping monitors

Ping (ICMP) monitors run the image's `ping`, which carries a `cap_net_raw` file capability. With every capability
dropped the kernel refuses to even start it. `pingMonitors.enabled: true`:

- sets the safe sysctl `net.ipv4.ping_group_range=0 2147483647` on the pod, so `ping` can use unprivileged ICMP
  sockets;
- keeps `NET_RAW` in the container capability **bounding set only**, so `ping` can be executed. Kener runs as
  uid 1000 with `allowPrivilegeEscalation: false`, so neither Node.js nor `ping` actually holds `NET_RAW`.

`NET_RAW` is still listed in `securityContext.capabilities.add`, which the Pod Security Standards `restricted` and
`baseline` both refuse: in a namespace that enforces either of them, the pods are rejected. Label the namespace
`pod-security.kubernetes.io/enforce=privileged` (or do not enforce any level) before enabling it. HTTP, TCP, DNS,
SSL, SQL, gRPC and heartbeat monitors do not need it.

```yaml
pingMonitors:
  enabled: true
```

### Monitor eval code

Since Kener 4.2, API, Ping, TCP and GameDig monitors run their eval code (the built-in one when a monitor has none) in
a [sandbox](https://kener.ing/docs/v4/monitors/overview#eval-sandbox): a QuickJS engine compiled to WebAssembly,
inside a new Node.js process that Kener starts for each check and kills when the eval returns. An eval is stopped
after 10 seconds, at most 2 run at a time (the next one waits for a free slot), and the eval process gets only `TZ`
from the container environment. Eval code cannot reach the files of the container, its environment
variables (secrets included) or the network: `fetch`, `process`, `require`, `Buffer`, `setTimeout`, `URL`, `crypto`,
`Intl` and the other Node.js and browser features do not exist there.

The chart needs no setting for it. The eval process runs in the Kener container with the same security context
(uid 1000, read-only root filesystem, no capability, no privilege escalation, seccomp `RuntimeDefault`), writes no
file, and talks to Kener through a socket pair it inherits, not over the network, so NetworkPolicies do not concern
it. What it needs is memory, inside the container `resources.limits.memory`: each running eval adds a Node.js process
of about 70 MiB plus what the eval allocates. In the end-to-end test, Kener itself used 240 to 330 MiB, each eval
process 65 to 75 MiB, and the container stayed under 230 MiB with the default `1Gi` limit.

**The eval memory limit is not enforced.** Kener sets a 256 MB limit on the QuickJS engine of each eval, but Kener
4.2.1 does not hold the eval process to it. In the end-to-end test of this chart, an eval that kept allocating 16 MiB
typed arrays grew its process past 1.7 GiB, until the container reached its memory limit and was `OOMKilled`, with
the default `1Gi` and with `2Gi` alike. Kubernetes restarts Kener, and the monitor runs again at its next check (see
[Troubleshooting](#troubleshooting)). No memory limit absorbs this, so the chart keeps `1Gi`: anyone allowed to edit
monitors can restart Kener this way (before 4.2, they could run any code inside Kener). Give that permission
accordingly.

`Date` in eval code uses the container time zone, `TZ` (`UTC` in the image, `extraEnv` can change it).

### Resources and probes

Defaults: Kener requests `100m`/`256Mi` with a `1Gi` memory limit (Kener recommends 1 vCPU and 1 GiB for real
workloads), Valkey `25m`/`32Mi` with a `256Mi` limit. The Kener limit also covers the eval processes of the monitors,
up to 2 at a time (see [Monitor eval code](#monitor-eval-code)).

```yaml
resources:
  requests:
    cpu: "1"
    memory: 1Gi
  limits:
    memory: 1Gi
```

When a probe has no handler, the chart adds an `httpGet` on the base path: liveness and startup on
`<basePath>/healthcheck` (200 while the server answers), readiness on `<basePath>/healthcheck?strict=1` (503 while
the database or Redis is unreachable). `enabled: false`, or the probe set to `null`, removes a probe. The liveness
probe tolerates 2 minutes (6 × 20 s) and the startup probe 5 minutes (60 × 5 s); large SQLite migrations block the
process at the first start of a new version, so raise them for very large databases:

```yaml
livenessProbe:
  failureThreshold: 30     # 30 x 20 s = 10 minutes for a long migration
```

### Scaling

`replicaCount` must stay at 1 with SQLite. With PostgreSQL or MySQL and a shared Redis (bundled or external),
several replicas or the HPA work, which is how Kener 4 is designed, but it is not tested upstream:

```yaml
database:
  existingSecret: kener-database
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 4
  targetCPUUtilizationPercentage: 80
podDisruptionBudget:
  enabled: true
  maxUnavailable: 1
```

The PodDisruptionBudget uses `minAvailable: 1` unless `maxUnavailable` is set. A budget that never allows an
eviction blocks node drains, so the chart refuses it with SQLite (always one pod), and refuses a `minAvailable` that
is not lower than `replicaCount` (`autoscaling.minReplicas` with the HPA). The bundled Valkey always runs one pod.

### Scheduling

`nodeSelector`, `tolerations`, `affinity`, `topologySpreadConstraints` and `priorityClassName` apply to the Kener
pods; `redis.nodeSelector`, `redis.tolerations`, `redis.affinity` and `redis.priorityClassName` to the Valkey pod
(it has no topology spread setting).

```yaml
nodeSelector:
  kubernetes.io/arch: arm64
tolerations:
  - key: dedicated
    operator: Equal
    value: monitoring
    effect: NoSchedule
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: kener
redis:
  nodeSelector:
    kubernetes.io/arch: arm64
  tolerations:
    - key: dedicated
      operator: Equal
      value: monitoring
      effect: NoSchedule
```

### NetworkPolicy

`networkPolicy.enabled: true` creates two policies:

- `status-kener`: only TCP 3000 is accepted. With `networkPolicy.ingressFrom` empty, any source may reach it; with
  peers listed, only these peers and the pods of the release (the `helm test` pod) may. Egress is not restricted:
  monitors probe arbitrary hosts.
- `status-kener-valkey` (bundled Valkey only): only the Kener pods may reach port 6379, and Valkey has no egress at
  all.

```yaml
networkPolicy:
  enabled: true
  ingressFrom:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
      podSelector:
        matchLabels:
          app.kubernetes.io/name: ingress-nginx
```

An Ingress controller running with `hostNetwork` is not matched by a pod or namespace selector: allow its node
addresses with an `ipBlock` peer instead.

### Monitoring

The chart creates no ServiceMonitor and Kener exposes no Prometheus metrics. `<basePath>/healthcheck` answers JSON
(`status`, `db`, `redis`); with `?strict=1` it returns 503 when the database or Redis is down, which an external
probe (blackbox exporter, another status page) can watch.

### Extra environment and volumes

`extraEnv`, `extraEnvFrom`, `extraVolumes` and `extraVolumeMounts` are added to the Kener container. For example, to
let monitors trust an internal certificate authority:

```yaml
extraEnv:
  - name: NODE_EXTRA_CA_CERTS
    value: /etc/kener/ca/ca.crt
extraVolumes:
  - name: internal-ca
    configMap:
      name: internal-ca
extraVolumeMounts:
  - name: internal-ca
    mountPath: /etc/kener/ca
    readOnly: true
```

The image sets `NODE_OPTIONS=--experimental-strip-types`, which Kener needs to load its migrations: the chart refuses
an `extraEnv` `NODE_OPTIONS` without it.

## Examples

### Public status page behind an Ingress

```yaml
kener:
  origin: https://status.example.com
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
  hosts:
    - host: status.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: status-example-com-tls
      hosts:
        - status.example.com
networkPolicy:
  enabled: true
  ingressFrom:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
```

### Under `/status` with the Gateway API

The base path is compiled into the Kener image: the chart picks the upstream `-status` image
(`4.2.1-status-alpine`) when `kener.basePath` is `/status`. Any other path needs your own build
(`KENER_BASE_PATH` build argument) in `image.tag`.

```yaml
kener:
  origin: https://example.com      # origin only, never the /status path
  basePath: /status
httpRoute:
  enabled: true
  parentRefs:
    - name: main-gateway
      namespace: gateway-system
      sectionName: https
  hostnames:
    - example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /status
```

### PostgreSQL, external Redis and two replicas

```yaml
kener:
  origin: https://status.example.com
  existingSecret: kener            # key: secret-key
database:
  existingSecret: kener            # key: database-url = postgresql://kener:<password>@db-rw.databases.svc:5432/kener
redis:
  enabled: false
  external:
    existingSecret: kener          # key: redis-url = rediss://default:<password>@redis.example.com:6379
replicaCount: 2
podDisruptionBudget:
  enabled: true
```

Kener only accepts `postgresql://` (not `postgres://`) and `mysql://` URLs. Percent-encode reserved characters of the
password (`@` → `%40`, `/` → `%2F`, `:` → `%3A`...). Several replicas sharing one database and one Redis is how
Kener 4 is designed, but it is not tested upstream: keep `replicas × (DATABASE_POOL_MAX + DATABASE_WORKER_POOL_MAX)`
(10 + 5 per replica by default, see `database.pool`) below the database `max_connections`.

### Email through SMTP

```yaml
email:
  smtp:
    host: smtp.example.com
    port: 587
    user: status@example.com
    existingSecret: kener-smtp     # key: smtp-password
    fromEmail: Status <status@example.com>
```

Resend works the same way with `email.resend` (SMTP wins when both are set). User invitations and email
verification need one of them.

## Security

What the chart does by default:

- **Users**: Kener runs as uid/gid 1000 (the `node` user of the image), Valkey as uid 999 / gid 1000, both with
  `runAsNonRoot` and `fsGroup: 1000` (`fsGroupChangePolicy: OnRootMismatch`).
- **Containers**: read-only root filesystem (the writable paths are the emptyDirs and volumes listed in
  [Architecture](#architecture)), `allowPrivilegeEscalation: false`, every capability dropped, seccomp
  `RuntimeDefault`. The default pods, the test pod included, meet the Pod Security Standard `restricted`;
  `pingMonitors.enabled` is the only setting that leaves it (see [Ping monitors](#ping-monitors)).
- **Kubernetes API**: the service account token is not mounted (`automountServiceAccountToken: false` on the
  ServiceAccount and the pods), and the chart creates no Role. `enableServiceLinks: false` keeps Service variables
  out of the environment.
- **Secrets**: every secret reaches the containers through `secretKeyRef`, never as a plain value in the pod spec.
  `REDIS_URL` is built by Kubernetes from the secret-backed `REDIS_PASSWORD` (`$(REDIS_PASSWORD)`), and Valkey reads
  its password from a secret-backed variable on standard input at startup, so the password is neither in the
  ConfigMap nor in the process arguments. See [Secrets and existing Secrets](#secrets-and-existing-secrets).
- **Network**: everything is `ClusterIP` until you add an Ingress, an HTTPRoute or another Service type.
  `networkPolicy.enabled` restricts Kener to its HTTP port and Valkey to Kener (see [NetworkPolicy](#networkpolicy)).

What is exposed, and to whom: the Kener Service serves the public status pages, the dashboard (`/manage`, login
required), the REST API (`/api/v4`, API key required), the heartbeat endpoints and the sign-in page on the same
port. Valkey is only reachable inside the cluster, with its password.

Caveats:

- Anyone who reaches Kener before an account exists can create the administrator account: create it right after
  the install, before publishing the page.
- Kener substitutes any environment variable in monitors and triggers, secrets included (see
  [Secrets for monitors and triggers](#secrets-for-monitors-and-triggers)): monitor and trigger editors can read
  every secret of the container.
- Monitor eval code runs in a sandbox since Kener 4.2 (see [Monitor eval code](#monitor-eval-code)). Before, it ran
  inside the Kener process, with its environment, files and network: anyone allowed to edit monitors could run any
  code there. They can still get Kener `OOMKilled` with an eval that allocates without bound. The `$NAME`
  substitution above is not affected by the sandbox.
- Kener egress stays open with `networkPolicy.enabled`, since monitors reach arbitrary hosts. Add your own egress
  policy if your monitors only target known networks.
- The Kener-Valkey traffic is not encrypted inside the cluster.
- The generated secrets live in the `status-kener` Secret, which `helm uninstall` keeps along with the database
  (see [Uninstalling](#uninstalling)): delete both deliberately when you remove Kener for good. With GitOps tools,
  use your own Secrets.
- The chart runs the upstream images, whose known vulnerabilities are tracked in the
  [CVE watch](https://github.com/UnxWares/helm/issues?q=is%3Aissue+is%3Aopen+label%3Acve-watch).

Report security problems as described in [SECURITY.md](https://github.com/UnxWares/helm/blob/main/SECURITY.md).

## Testing

Every pull request of the [repository](https://github.com/UnxWares/helm) runs, for this chart:

- `helm lint --strict` with Helm 3 and Helm 4, on the default values and on each `ci/*-values.yaml`;
- kubeconform (strict) on the manifests rendered with the same values, for Kubernetes 1.31 and 1.34;
- `ct lint` (chart-testing: `Chart.yaml` schema, YAML lint, `helm lint`, version increment);
- `ct install` on a kind cluster, once per `ci/*-values.yaml`, which installs the chart and runs its `helm test`:
  - `ci/default-values.yaml`: SQLite on a PVC, bundled Valkey, NetworkPolicies on, Alpine image;
  - `ci/status-debian-values.yaml`: `/status` base path on the Debian image, persistent Valkey, ping monitors
    enabled;
- the Artifact Hub lint (`ah lint`) and a check that `README.md` and `values.schema.json` match `values.yaml`.

`ct lint` and `ct install` only run when the pull request changes the chart.

The `helm test` pod (`templates/tests/test-healthcheck.yaml`) runs `curl` from the Kener image (or `tests.image`)
against `http://status-kener:<service.port><basePath>/healthcheck?strict=1`, retrying 6 times 5 seconds apart. It
passes only when Kener answers and reaches both its database and Redis. It changes nothing, so it is safe on a real
instance. After an install:

```bash
helm test status -n status --logs
```

The end-to-end test (`.github/workflows/e2e.yaml`, script `.github/scripts/kener-e2e.sh`) runs on pull requests
that change the chart, on every push to main and every week. It installs the chart in kind with
`ci/default-values.yaml` and the upstream images, runs `helm test`, then, through the Service:

- the first account signs up from the sign-in page, and a second sign-up is refused;
- the account logs in (not with a wrong password) and creates an API key; the REST API refuses requests without a
  valid key, including through a percent-encoded path (the authentication bypass fixed in Kener 4.1.9);
- an HTTP monitor and a status page are created through the REST API; the monitor runs from the queue (bundled
  Valkey) and records `UP`; the status page lists it as operational, its monitor page and its status badge answer;
- monitor eval code runs in the Kener sandbox inside the hardened pod: an HTTP monitor whose custom eval reads the
  health check answer, and finds none of `process`, `require`, `fetch` and `Buffer`, records the status and latency
  that the eval returns; evals that read `process.env` or loop forever record `DOWN` with the sandbox error
  (`'process' is not defined`, `Timed out after 10000 ms`), and the Kener container does not restart; the memory of
  the container, of Kener and of its eval processes is printed. An eval that exhausts its memory is not part of the
  test: it gets Kener `OOMKilled` (see [Monitor eval code](#monitor-eval-code));
- Valkey refuses commands without its password; Kener reaches Valkey, another pod reaches Kener but not Valkey
  (NetworkPolicies);
- after `helm uninstall` and a new install, the account logs in with the same password and the API key created
  before still works (kept PVC and Secret).

It does not test notifications (email, webhooks), ping monitors, the Debian or `/status` images (installed by
`ct install` only), PostgreSQL or MySQL, an external Redis, or several replicas.

Unit tests (`tests/*_test.yaml`, [helm-unittest](https://github.com/helm-unittest/helm-unittest), run by
`.github/workflows/unit.yaml` on pull requests, every push to main and every Tuesday) render the chart without a
cluster and check the security contexts of Kener, Valkey and the test pod (with and without `pingMonitors.enabled`),
the image tag built from the variant and the base path, the message of every required value, the chart Secret
(generated values reused at upgrade, keep policy, keys left out for your own Secrets), secrets passed through
`secretKeyRef` only, the probes, persistence, the Valkey configuration, the Services, Ingress, HTTPRoute,
NetworkPolicies, HPA and PDB, the release notes and the four examples of this README.

## Operations

### Backup and restore

With SQLite, the image ships the `sqlite3` client: dump the database while Kener runs (the dump is consistent):

```bash
kubectl -n status exec deploy/status-kener -- \
  sqlite3 /app/database/kener.sqlite.db .dump > kener-$(date +%F).sql
```

To restore, load the dump into a new file next to the live database, then point Kener at it with `database.url` in
your values and upgrade: the pod is recreated on the new file, and the old one stays on the volume.

```bash
kubectl -n status exec -i deploy/status-kener -- \
  sqlite3 /app/database/kener-restored.db < kener-2026-11-02.sql
```

```yaml
database:
  url: sqlite://./database/kener-restored.db
```

Volume snapshots of the `status-kener` PVC (CSI `VolumeSnapshot`, Velero...) are another option. With PostgreSQL or
MySQL, back up the database with its own tools (`pg_dump`, `mysqldump`...). Valkey only holds queues and caches and
needs no backup.

Also keep `KENER_SECRET_KEY`: API keys are stored as HMACs of it, so a restore with another key invalidates them and
logs everybody out.

```bash
kubectl -n status get secret status-kener -o jsonpath='{.data.secret-key}' | base64 -d
```

### Scaling limits

- SQLite: one replica, enforced by the chart, replaced with the `Recreate` strategy when on a PVC (a short downtime
  at each upgrade).
- PostgreSQL/MySQL: several replicas share the database and Redis (not tested upstream), within the database
  connection budget (see [Database](#database)).
- The bundled Valkey is a single pod without replication: for a highly available Redis, use `redis.external`.

### Logs and useful commands

```bash
kubectl -n status logs deploy/status-kener                 # Kener, migrations at startup included
kubectl -n status logs deploy/status-kener-valkey          # Valkey
kubectl -n status exec deploy/status-kener -- curl -s http://localhost:3000/healthcheck
kubectl -n status exec deploy/status-kener-valkey -- valkey-cli ping   # authenticates through VALKEYCLI_AUTH
kubectl -n status rollout restart deploy/status-kener
```

With a base path, the health check is `http://localhost:3000/status/healthcheck`.

## Upgrading

Read the notes of every version between yours and the target, back up the database (see
[Backup and restore](#backup-and-restore)), then run `helm upgrade` with your values file:

```bash
helm repo update
helm upgrade status unxwares/kener -n status -f values.yaml
```

### To 2026.11.7 (Kener 4.2.1)

Security release, no value to change, but review the eval code of your monitors before upgrading:

- Kener 4.2 runs the eval code of API, Ping, TCP and GameDig monitors in a sandbox (see
  [Monitor eval code](#monitor-eval-code)). Eval code that uses `fetch`, `process`, `require`, `import()`, `Buffer`,
  `setTimeout`, `URL`, `TextDecoder`, `crypto` or `Intl` now reports **DOWN** with an error such as
  `'fetch' is not defined`, and so does a Ping, TCP or GameDig eval that returns a `status` other than `UP`,
  `DEGRADED`, `DOWN` or `MAINTENANCE`. Search your evals for these names and rewrite them as the
  [4.2.0 changelog](https://kener.ing/docs/v4/changelogs/v4.2.0) explains. `modules.cheerio` stays, about 20 times
  slower, without `fromURL`, `loadBuffer`, `stringStream` and `decodeStream`.
- Each check of these monitors starts a short-lived Node.js process in the Kener container: count about 70 MiB per
  running eval, 2 at most, plus what the eval allocates, in `resources.limits.memory`. Kener 4.2.1 does not hold
  that process to its 256 MB eval limit: an eval that allocates without bound gets Kener `OOMKilled` whatever the
  limit (see [Monitor eval code](#monitor-eval-code)).
- A migration adds the nullable `maintenances.timezone` column at the first start. Existing recurring maintenances
  keep repeating in UTC; give one a time zone to keep its local time across clock changes.
- The chart skips Kener 4.2.0, whose eval sandbox could hang and then report every such monitor **DOWN** until a
  restart. If you had set `image.tag` to a 4.2.0 image, empty it or move to 4.2.1.

### To 2026.11.3

- The `status-kener` Secret (generated `KENER_SECRET_KEY` and Valkey password) is now kept on `helm uninstall`, like
  the SQLite PVC, so that a new install keeps sessions and API keys working. Delete it yourself when you remove
  Kener for good (see [Uninstalling](#uninstalling)).
- `podDisruptionBudget.enabled: true` is refused with SQLite, and when `minAvailable` is not lower than the number
  of replicas: these budgets blocked node drains. If `helm upgrade` stops on this error, set
  `podDisruptionBudget.enabled: false` (or scale out on PostgreSQL/MySQL, or set `maxUnavailable`).
- An empty `redis.image.tag` no longer falls back to a Valkey tag hidden in the templates: keep a tag (the default
  is `9.1.3-alpine`) or set `redis.image.digest`.
- The proxy URLs can come from your own Secret: `proxy.existingSecret`.

### To 2026.11.1 (Kener 4.1.11)

Security release, no value to change. Kener 4.1.11 updates dependencies with known vulnerabilities and masks the
secrets stored in monitors and triggers when they are read through the API or the dashboard. It also checks the bodies
of `/api/v4` writes against the API specification: a client that sent fields the specification does not allow now gets
a `400` and has to be fixed.

### To 2026.10.2 (Kener 4.1.10)

Security release, no value to change. Kener 4.1.9 fixes an authentication bypass: from 4.0.0 to 4.1.8, a
percent-encoded path such as `/%61pi/v4/monitors` reached every `/api/v4` route without an API key. If the instance
was reachable from an untrusted network, follow the steps of the
[4.1.9 changelog](https://kener.ing/docs/v4/changelogs/v4.1.9): look for such requests in the access logs, review
monitors, incidents and pages, and rotate the tokens stored in monitors.

### From 2026.2.x (Kener 3.2.19) to 2026.10.1 (Kener 4.1.7)

Kener 4 is a major release. Back up the database first (the PVC mounted on `/app/database`, or your
PostgreSQL/MySQL database): the migrations run automatically at the first start and cannot be rolled back.

Chart changes:

1. **Secret key**: the previous chart shipped a default `KENER_SECRET_KEY` (`thesuperprivatekeytonotshare`). It was
   public: anyone could forge a session for any account. The chart now refuses it and generates a random key unless
   you set one. After the upgrade everybody logs in again and API keys created before must be re-created. If you
   had set your own key, it is kept (`kener.key` and `kener.keyFrom` still work, prefer `kener.secretKey` and
   `kener.existingSecret` + `kener.existingSecretKey`).
2. **SQLite data**: the previous chart had no persistence. If you mounted your own PVC on `/app/database` through
   `volumes`/`volumeMounts`, remove these entries and set `persistence.existingClaim: <your PVC>` (the chart refuses a
   second mount on `/app/database`). Without such a volume the data lived in the container and cannot be recovered.
   `/app/uploads` is gone: Kener 4 stores images in the database.
3. **External database**: `database.url` and `database.existingSecret` keep their meaning, but the URL now goes
   through a Secret and must start with `postgresql://` or `mysql://`. `database.secretKeys.url` becomes
   `database.existingSecretKey`, and `database.enabled: false` is simply an empty `database.url` (both old names still
   work). The old default URL (`postgresql://user:password@host:port/db`) is gone: SQLite is now the default.
4. **Redis** is mandatory: the bundled Valkey is deployed unless you set `redis.enabled: false` and `redis.external`.
5. **Image**: `docker.io/rajnandan1/kener:4.1.7-alpine` by default (`image.variant: debian` for the upstream
   default). The container always listens on 3000; `service.port` only changes the Service.
6. **Security context**: pods run as uid/gid 1000 (the image `node` user, as before) with a read-only root
   filesystem. Files of an existing volume are made group-accessible through `fsGroup: 1000`.
7. `kener.origin` now defaults to `http://localhost:3000` and is validated (no path, no trailing slash): set it to
   your public URL. The HTTPRoute default rule now routes `PathPrefix /` (it only matched `/headers`).
8. The Deployment keeps its name and selector, so `helm upgrade` works in place; with SQLite it switches to the
   `Recreate` strategy. If the upgrade is refused with `spec.strategy.rollingUpdate: Forbidden`, delete the
   Deployment (`kubectl delete deploy <release>-kener`, the data is on the PVC) and run `helm upgrade` again.

Kener changes ([v4.0.0 notes](https://kener.ing/docs/v4/changelogs/v4.0.0)), to handle after the upgrade:

- Heartbeat monitors: update callers to `/ext/heartbeat/{tag}:{secret}`.
- REST API: v3 routes are gone, use `/api/v4/*`.
- Re-upload the logo and favicon (**Manage → Site**): `/uploads/...` URLs return 404. Host custom fonts elsewhere.
- Assign monitors to a page (**Manage → Pages**): they are hidden until then.
- Open and save monitors that had a custom timeout (string to number fix).
- Subscriptions and subscribers are not migrated: configure them again.

## Troubleshooting

**`helm install` fails with an `execution error`**: the chart validates its values and says what to change (origin
with a path or a trailing slash, base path without a matching image, `postgres://` URL, several replicas on SQLite,
a PodDisruptionBudget with SQLite or with `minAvailable` not lower than the replicas, `redis.enabled: false` without
`redis.external`, no Valkey tag or digest, incomplete SMTP settings, `NODE_OPTIONS` without
`--experimental-strip-types`, public secret key).

**Login and every form fail** (SvelteKit answers `Cross-site POST form submissions are forbidden`): `kener.origin`
does not match the URL in the browser (scheme, host and port). NOTES warn when an Ingress or HTTPRoute is enabled
while the origin is still `localhost`.

**The pod is running but not ready**: the strict health check reports which dependency is down:

```bash
kubectl -n status exec deploy/status-kener -- curl -s 'http://localhost:3000/healthcheck?strict=1'
# {"status":"degraded","db":true,"redis":false}
kubectl -n status logs deploy/status-kener
```

With `redis: false`, check the Valkey pod (`kubectl -n status get pods`, and `valkey-cli ping` as in
[Operations](#logs-and-useful-commands)) or the external Redis URL; with NetworkPolicies, the Kener pods must keep
their default labels. With `db: false`, check the database URL (scheme, percent-encoding) and that the database is
reachable from the namespace.

**Errors after an upgrade**: when a migration fails, Kener logs `Error running migrations` and keeps running; read
the first lines of `kubectl logs` after each upgrade. If the upgrade is refused with
`spec.strategy.rollingUpdate: Forbidden`, see the 2026.10.1 upgrading note.

**Everybody is logged out and API keys stopped working**: `KENER_SECRET_KEY` changed, usually because a GitOps tool
renders the chart offline, or after a reinstall. Use your own Secret (see
[Secrets and existing Secrets](#secrets-and-existing-secrets)).

**A monitor reports DOWN since the upgrade to 2026.11.7**, with `is not defined` in the error of its checks: its eval
code uses a Node.js or browser feature that the Kener 4.2 sandbox does not have (see
[Monitor eval code](#monitor-eval-code) and the 2026.11.7 upgrading note). `Eval error: Timed out after 10000 ms`
means the eval ran for more than 10 seconds.

**Kener is `OOMKilled` again and again, at each check of a monitor**: an eval allocates memory without bound (see
[Monitor eval code](#monitor-eval-code)), and a higher memory limit does not help. Deactivate the monitor in the
dashboard while Kener is up, or in the database, for example with SQLite, then fix its eval:

```bash
kubectl -n status exec deploy/status-kener -- sqlite3 /app/database/kener.sqlite.db \
  "UPDATE monitors SET status = 'INACTIVE' WHERE tag = '<monitor tag>'"
```

**Ping monitors fail** (`Operation not permitted`): set `pingMonitors.enabled: true`. If the pods are then not
created, the namespace Pod Security level refuses `NET_RAW`:

```bash
kubectl -n status get events --field-selector reason=FailedCreate
kubectl label namespace status pod-security.kubernetes.io/enforce=privileged --overwrite
```

**The PVC stays `Pending`**: there is no default StorageClass, or it cannot provide `ReadWriteOnce`. Check with
`kubectl -n status describe pvc status-kener` and set `persistence.storageClass`.

**The Ingress answers 502/504 with `networkPolicy.enabled`**: `networkPolicy.ingressFrom` does not match the Ingress
controller pods (check their namespace labels; use an `ipBlock` for a `hostNetwork` controller).

## Uninstalling

```bash
helm uninstall status -n status
```

This deletes the Deployments, Services, ConfigMap, ServiceAccount, Ingress/HTTPRoute, NetworkPolicies, PDB and HPA.
It keeps, annotated `helm.sh/resource-policy: keep`:

- the `status-kener` PVC (SQLite database) and the `status-kener-valkey` PVC (with `redis.persistence.enabled`);
- the `status-kener` Secret, generated `KENER_SECRET_KEY` and Valkey password included.

It never touches the PVCs and Secrets you created yourself (`existingClaim`, `existingSecret`). The chart creates no
StatefulSet, so no other PVC is left behind. A new install under the same release name and namespace takes the kept
PVC and Secret over again: accounts, sessions and API keys keep working. To delete the data and the secrets for
good:

```bash
kubectl -n status delete pvc status-kener status-kener-valkey
kubectl -n status delete secret status-kener
```

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity rules. |
| autoscaling.enabled | bool | `false` | Enable the HorizontalPodAutoscaler (PostgreSQL/MySQL only, not tested upstream). |
| autoscaling.maxReplicas | int | `4` | Maximum replicas. |
| autoscaling.minReplicas | int | `2` | Minimum replicas. |
| autoscaling.targetCPUUtilizationPercentage | int | `80` | Target CPU utilization. |
| autoscaling.targetMemoryUtilizationPercentage | string | `nil` | Target memory utilization. |
| commonLabels | object | `{}` | Labels added to every resource. |
| database.existingSecret | string | `""` | Existing secret holding the database URL (`postgresql://` or `mysql://`). Takes precedence over `database.url`. |
| database.existingSecretKey | string | `"database-url"` | Key of the URL in `existingSecret`. |
| database.keepAlive | string | `nil` | `DATABASE_KEEPALIVE`: TCP keepalive on database connections. Null keeps the Kener default (`true`). |
| database.pool.acquireTimeoutMs | string | `nil` | `DATABASE_ACQUIRE_TIMEOUT_MS` (Kener default 15000). |
| database.pool.createTimeoutMs | string | `nil` | `DATABASE_CREATE_TIMEOUT_MS` (Kener default 15000). |
| database.pool.idleTimeoutMs | string | `nil` | `DATABASE_IDLE_TIMEOUT_MS` (Kener default 30000). |
| database.pool.max | string | `nil` | `DATABASE_POOL_MAX`: connections serving web requests, per replica (Kener default 10). Keep `replicas x (max + workerMax)` below the database `max_connections`. |
| database.pool.min | string | `nil` | `DATABASE_POOL_MIN` (PostgreSQL/MySQL). Null keeps the Kener default (0). |
| database.pool.workerMax | string | `nil` | `DATABASE_WORKER_POOL_MAX`: connections of the background jobs, per replica (Kener default 5). |
| database.url | string | `""` | External database URL: `postgresql://user:password@host:5432/kener` or `mysql://user:password@host:3306/kener` (stored in a Secret; percent-encode reserved characters of the password). Empty uses SQLite in `/app/database`. |
| email.resend.apiKey | string | `""` | Resend API key (`RESEND_API_KEY`, stored in a Secret; ignored when `existingSecret` is set). |
| email.resend.existingSecret | string | `""` | Existing secret holding the Resend API key. |
| email.resend.existingSecretKey | string | `"resend-api-key"` | Key of the API key in `existingSecret`. |
| email.resend.senderEmail | string | `""` | Sender address (`RESEND_SENDER_EMAIL`), required with Resend. |
| email.smtp.existingSecret | string | `""` | Existing secret holding the SMTP password. |
| email.smtp.existingSecretPasswordKey | string | `"smtp-password"` | Key of the password in `existingSecret`. |
| email.smtp.fromEmail | string | `""` | Sender address (`SMTP_FROM_EMAIL`), e.g. `Status <status@example.com>`. |
| email.smtp.host | string | `""` | SMTP host (`SMTP_HOST`). Kener uses SMTP from the environment only when host, port, user, sender and password are all set. |
| email.smtp.password | string | `""` | SMTP password (`SMTP_PASS`, stored in a Secret; ignored when `existingSecret` is set). |
| email.smtp.port | int | `587` | SMTP port (`SMTP_PORT`). |
| email.smtp.secure | bool | `false` | Implicit TLS (`SMTP_SECURE=1`, usually port 465). Keep `false` for STARTTLS on port 587. |
| email.smtp.user | string | `""` | SMTP user (`SMTP_USER`). |
| extraEnv | list | `[]` | Extra environment variables of the Kener container. Kener substitutes `$NAME` variables in monitors and triggers: pass their secrets here with `valueFrom.secretKeyRef`. Never drop `--experimental-strip-types` if you set `NODE_OPTIONS`. |
| extraEnvFrom | list | `[]` | Extra `envFrom` sources of the Kener container. |
| extraVolumeMounts | list | `[]` | Extra volume mounts of the Kener container. Do not mount `/app/database`: use `persistence.existingClaim`. |
| extraVolumes | list | `[]` | Extra volumes. |
| fullnameOverride | string | `""` | Override the full resource names. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Create a Gateway API HTTPRoute. |
| httpRoute.hostnames | list | `["status.example.com"]` | Hostnames. |
| httpRoute.parentRefs | list | `[{"name":"gateway","sectionName":"http"}]` | Gateways this route attaches to. |
| httpRoute.rules | list | `[{"matches":[{"path":{"type":"PathPrefix","value":"/"}}]}]` | Rules (`matches`, `filters`); each one is sent to the Kener service. With `kener.basePath`, match that path instead of `/`. |
| image.digest | string | `""` | Image digest (`sha256:...`). When set, it takes precedence over the tag. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"docker.io/rajnandan1/kener"` | Kener image repository. |
| image.tag | string | `""` | Image tag. Empty builds it from the chart appVersion, `kener.basePath` and `image.variant` (`4.2.1-alpine`, `4.2.1`, `4.2.1-status-alpine`...). |
| image.variant | string | `"alpine"` | Base of the published image when `image.tag` is empty: `alpine` (node:24-alpine, far fewer known CVEs) or `debian` (node:24-slim, the upstream default). |
| imagePullSecrets | list | `[]` | Secrets for pulling images from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Create an Ingress. |
| ingress.hosts | list | `[{"host":"status.example.com","paths":[{"path":"/","pathType":"Prefix"}]}]` | Hosts and paths. With `kener.basePath`, route that path (e.g. `/status`). |
| ingress.tls | list | `[]` | TLS settings. |
| kener.basePath | string | `""` | Serve Kener under a sub path (`KENER_BASE_PATH`). The base path is compiled into the image: published images exist for `""` and `/status` (the `-status` tags, picked automatically). Any other path needs your own image in `image.tag`. |
| kener.bodySizeLimit | string | `"3M"` | Maximum request body size (`BODY_SIZE_LIMIT`), raise it to upload larger images. |
| kener.existingSecret | string | `""` | Existing secret holding the secret key. |
| kener.existingSecretKey | string | `"secret-key"` | Key of the secret key in `existingSecret`. |
| kener.forceLocalLogin | bool | `false` | Re-enable the email/password login when it is disabled in the OpenID Connect settings (`KENER_FORCE_LOCAL_LOGIN`). Emergency use only: turn it off once the identity provider works again. |
| kener.nodeEnv | string | `"production"` | `NODE_ENV` of the Kener process. |
| kener.origin | string | `"http://localhost:3000"` | Public URL of Kener (`ORIGIN`): scheme + host + optional port, no path, no trailing slash (e.g. `https://status.example.com`). It must match the URL in the browser or every form (login included) is rejected; `https://` also turns on secure cookies. The default only suits `kubectl port-forward`. |
| kener.secretKey | string | `""` | Secret key (`KENER_SECRET_KEY`, 32+ characters) signing sessions and hashing API keys. Leave empty to generate one (kept across upgrades). Set it, or use `existingSecret`, with GitOps tools that render templates offline: changing it logs everybody out and invalidates every API key. |
| livenessProbe | object | `{"enabled":true,"failureThreshold":6,"periodSeconds":20,"timeoutSeconds":5}` | Liveness probe (`enabled: false` or `null` removes it). Without a handler, the chart adds `httpGet <basePath>/healthcheck` (always 200 while the server answers). Generous on purpose: large SQLite migrations block the process at the first start of a new version. |
| nameOverride | string | `""` | Override the chart name. |
| networkPolicy.enabled | bool | `false` | Create NetworkPolicies: Kener only accepts traffic on its HTTP port, and the bundled Valkey only accepts Kener pods (no egress at all). |
| networkPolicy.ingressFrom | list | `[]` | Peers allowed to reach Kener (e.g. your ingress controller). Empty allows any source on the HTTP port; pods of this release are always allowed. |
| nodeSelector | object | `{}` | Node selector. |
| persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes. |
| persistence.annotations | object | `{}` | PVC annotations. |
| persistence.enabled | bool | `true` | Persist the SQLite database (`/app/database`). Without it the database lives in an emptyDir and is lost with the pod. Unused with an external database. |
| persistence.existingClaim | string | `""` | Use an existing PVC (e.g. the one you mounted on `/app/database` with the previous chart). |
| persistence.size | string | `"2Gi"` | Volume size. |
| persistence.storageClass | string | `""` | Storage class (empty uses the cluster default). |
| pingMonitors.enabled | bool | `false` | Make ICMP ping monitors work with all capabilities dropped: sets the safe sysctl `net.ipv4.ping_group_range` so `ping` can use unprivileged ICMP sockets, and keeps `NET_RAW` in the capability bounding set only, so the image's `ping` (which carries a `cap_net_raw` file capability) can still be executed. The process never holds `NET_RAW` (non-root, no privilege escalation), but adding `NET_RAW` back to the bounding set is only allowed by the Pod Security Standard `privileged` (neither `baseline` nor `restricted`). |
| podAnnotations | object | `{}` | Pod annotations. |
| podDisruptionBudget.enabled | bool | `false` | Create a PodDisruptionBudget for Kener. Refused with SQLite (single replica) and when `minAvailable` is not lower than the replica count: such a budget blocks node drains. |
| podDisruptionBudget.maxUnavailable | string | `nil` | Maximum unavailable pods (used instead of minAvailable when set). |
| podDisruptionBudget.minAvailable | int | `1` | Minimum available pods (lower than `replicaCount`, or `autoscaling.minReplicas` with the HPA). |
| podLabels | object | `{}` | Pod labels. |
| podSecurityContext | object | `{"fsGroup":1000,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":1000,"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. The image user is `node` (uid/gid 1000). |
| priorityClassName | string | `""` | Priority class of the Kener pods. |
| proxy.existingSecret | string | `""` | Existing secret holding the proxy URLs instead of `httpProxy` and `httpsProxy` (either key may be missing). |
| proxy.existingSecretHttpProxyKey | string | `"http-proxy"` | Key of the `HTTP_PROXY` URL in `existingSecret`. |
| proxy.existingSecretHttpsProxyKey | string | `"https-proxy"` | Key of the `HTTPS_PROXY` URL in `existingSecret`. |
| proxy.httpProxy | string | `""` | `HTTP_PROXY` (stored in a Secret: it may carry credentials, percent-encoded). Ignored when `existingSecret` is set. |
| proxy.httpsProxy | string | `""` | `HTTPS_PROXY` (stored in a Secret). Ignored when `existingSecret` is set. |
| proxy.noProxy | string | `""` | `NO_PROXY`: hosts, `host:port`, `.suffix` (no CIDR). Add the in-cluster services your monitors reach directly. |
| readinessProbe | object | `{"enabled":true,"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":5}` | Readiness probe (`enabled: false` or `null` removes it). Without a handler, the chart adds `httpGet <basePath>/healthcheck?strict=1` (503 while the database or Redis is unreachable). |
| redis.affinity | object | `{}` | Affinity rules. |
| redis.auth.existingSecret | string | `""` | Existing secret holding the Valkey password (same character rules). |
| redis.auth.existingSecretPasswordKey | string | `"redis-password"` | Key of the password in `existingSecret`. |
| redis.auth.password | string | `""` | Password of the bundled Valkey. Leave empty to generate one (kept across upgrades). It is embedded in `REDIS_URL`, so only `A-Z a-z 0-9 . _ ~ -` are allowed. |
| redis.enabled | bool | `true` | Deploy a bundled single-instance Valkey (Redis compatible). Set to `false` and fill `redis.external` to use your own Redis 6+ / Valkey. |
| redis.external.existingSecret | string | `""` | Existing secret holding the full Redis URL. Takes precedence over `redis.external.url`. |
| redis.external.existingSecretKey | string | `"redis-url"` | Key of the URL in `existingSecret`. |
| redis.external.url | string | `""` | URL of your own Redis when `redis.enabled` is false: `redis://[user:password@]host:6379[/db]`, or `rediss://` for TLS (stored in a Secret). |
| redis.extraConfig | string | `""` | Raw lines appended to valkey.conf (e.g. `maxmemory 200mb`). Keep `maxmemory-policy noeviction`: BullMQ needs it. |
| redis.image.digest | string | `""` | Image digest (takes precedence over the tag). |
| redis.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| redis.image.repository | string | `"docker.io/valkey/valkey"` | Valkey image repository. |
| redis.image.tag | string | `"9.1.3-alpine"` | Valkey image tag (required unless `digest` is set). |
| redis.livenessProbe | object | `{"failureThreshold":4,"periodSeconds":15,"tcpSocket":{"port":"redis"},"timeoutSeconds":3}` | Valkey liveness probe. |
| redis.nodeSelector | object | `{}` | Node selector. |
| redis.persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes. |
| redis.persistence.annotations | object | `{}` | PVC annotations. |
| redis.persistence.enabled | bool | `false` | Keep Valkey data (AOF) on a PVC. Kener rebuilds its schedules from the database at startup, so an emptyDir is enough unless queued notifications must survive a Valkey restart. |
| redis.persistence.existingClaim | string | `""` | Use an existing PVC. |
| redis.persistence.size | string | `"1Gi"` | Volume size. |
| redis.persistence.storageClass | string | `""` | Storage class (empty uses the cluster default). |
| redis.podAnnotations | object | `{}` | Pod annotations. |
| redis.podLabels | object | `{}` | Pod labels. |
| redis.podSecurityContext | object | `{"fsGroup":1000,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":1000,"runAsNonRoot":true,"runAsUser":999,"seccompProfile":{"type":"RuntimeDefault"}}` | Valkey pod security context. The image user is `valkey` (uid 999, gid 1000). |
| redis.priorityClassName | string | `""` | Priority class of the Valkey pod. |
| redis.readinessProbe | object | `{"exec":{"command":["sh","-c","[ \"$(valkey-cli -h 127.0.0.1 -p 6379 ping)\" = PONG ]"]},"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":3}` | Valkey readiness probe (`valkey-cli ping`, authenticated through `VALKEYCLI_AUTH`). |
| redis.resources | object | `{"limits":{"memory":"256Mi"},"requests":{"cpu":"25m","memory":"32Mi"}}` | Valkey resources. |
| redis.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Valkey container security context. |
| redis.service.port | int | `6379` | Valkey service port. |
| redis.tolerations | list | `[]` | Tolerations. |
| replicaCount | int | `1` | Number of Kener replicas. Must stay at 1 with SQLite. PostgreSQL/MySQL with a shared Redis can run more (not tested upstream). |
| resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"256Mi"}}` | Resource requests and limits (Kener recommends 1 vCPU / 1 GiB for real workloads). Each check of an API, Ping, TCP or GameDig monitor runs its eval code (the built-in one when none is set) in a child process of the Kener container, up to 2 at a time, each about 70 MiB plus what the eval allocates. Kener 4.2.1 does not hold that process to its 256 MB eval limit: an eval that allocates without bound gets the container OOM-killed whatever the limit (see Monitor eval code in the README). |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. |
| service.annotations | object | `{}` | Service annotations. |
| service.port | int | `3000` | Service port (the container always listens on 3000). |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | Service account annotations. |
| serviceAccount.automount | bool | `false` | Kener never talks to the Kubernetes API: the token is not mounted. |
| serviceAccount.create | bool | `true` | Create a dedicated service account. |
| serviceAccount.name | string | `""` | Service account name (generated when empty). |
| startupProbe | object | `{"enabled":true,"failureThreshold":60,"periodSeconds":5,"timeoutSeconds":5}` | Startup probe (`enabled: false` or `null` removes it). Without a handler, the chart adds `httpGet <basePath>/healthcheck`. |
| tests.image | string | `""` | Image used by `helm test` (defaults to the Kener image, which ships curl). |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. |
| updateStrategy | object | `{}` | Deployment update strategy. With SQLite and persistence the chart forces `Recreate`. |

## License

The chart is released under the MIT license. Kener is licensed under the MIT license, Valkey under the BSD-3-Clause
license.
