# Kener Helm Chart

![Version: 2026.10.2](https://img.shields.io/badge/Version-2026.10.2-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 4.1.10](https://img.shields.io/badge/AppVersion-4.1.10-informational?style=flat-square)

[Kener](https://kener.ing) is an open source status page: monitors (HTTP, TCP, DNS, ping, SSL, SQL, gRPC,
heartbeat...), incidents, maintenances and subscriptions. This chart, maintained by UnxWares, runs Kener 4 on
Kubernetes with its mandatory Redis.

## Features

- **Kener 4** on SQLite (single replica + PVC kept on uninstall), PostgreSQL or MySQL. Database migrations run automatically at startup.
- **Bundled Valkey** (Redis compatible, required by Kener 4 for its queues): a single hardened pod with a generated password, no persistence by default since Kener rebuilds its schedules from the database. Or bring your own Redis 6+ through `redis.external`.
- **No default credentials**: `KENER_SECRET_KEY` and the Valkey password are generated and kept across upgrades, or read from your own Secrets. The database URL, Redis URL, SMTP password, Resend key and proxy URLs only reach the container through `secretKeyRef`.
- **Hardened by default**: non-root (uid 1000), read-only root filesystem, every capability dropped, seccomp `RuntimeDefault`, no service account token. The default pods meet the Pod Security Standard `restricted`.
- **Image choice**: Alpine variant by default (far fewer known CVEs than the Debian one), Debian on demand, and the upstream `-status` images for a `/status` base path.
- **Probes on `/healthcheck`**: readiness uses `?strict=1`, so a pod leaves the Service while its database or Redis is unreachable.
- Ingress or Gateway API HTTPRoute, optional NetworkPolicies (Valkey only reachable by Kener, without any egress), PodDisruptionBudget and HPA (SQL databases), `helm test`.

## Installation

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
helm install status unxwares/kener --namespace status --create-namespace \
  --set kener.origin=https://status.example.com
```

`kener.origin` must be the exact URL users type in their browser (scheme + host + optional port, no path, no
trailing slash): Kener rejects every form, login included, when it does not match. The default,
`http://localhost:3000`, only suits a quick test through `kubectl port-forward svc/status-kener 3000:3000`.

Then open `<origin><basePath>/account/signin` and create the administrator account. Kener lets **anyone** who
reaches this page create the first account while none exists: do it before exposing the page publicly (through a
port-forward, or with the Ingress restricted to your network).

Charts are signed: see [verifying signatures](https://github.com/UnxWares/helm/blob/main/SECURITY.md#verifying-chart-signatures)
and add `--verify --keyring <keyring>` to `helm install`.

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
(`4.1.10-status-alpine`) when `kener.basePath` is `/status`. Any other path needs your own build
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

### Secrets for monitors and triggers

Kener replaces `$NAME` in monitor URLs, headers, bodies, SQL connection strings and trigger settings with the
environment variable `NAME`. Pass them from a Secret, never as plain values:

```yaml
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

The pod then matches the Pod Security Standard `baseline` instead of `restricted` (only `NET_BIND_SERVICE` may be
added under `restricted`). HTTP, TCP, DNS, SSL, SQL, gRPC and heartbeat monitors do not need it.

## Notes

- **GitOps**: generated secrets cannot be read back by tools that render templates offline (Argo CD...), which would
  rotate them on every sync. A new `KENER_SECRET_KEY` logs everybody out **and invalidates every API key** (they are
  stored as HMACs of this key). Set `kener.secretKey` (32+ random characters) or `kener.existingSecret`, and
  `redis.auth.password` or `redis.auth.existingSecret`.
- **SQLite** supports a single replica: the chart refuses `replicaCount > 1` or the HPA with it and uses the
  `Recreate` strategy.
- **Valkey** keeps no data by default (`save ""`, no AOF): a restart only loses queued jobs (pending notifications);
  monitor schedules are rebuilt from the database. Set `redis.persistence.enabled` to keep them. The Valkey password
  is embedded in `REDIS_URL`, so it is limited to `A-Z a-z 0-9 . _ ~ -`.
- **`NODE_OPTIONS`**: the image sets `--experimental-strip-types`, which Kener needs to load its migrations. The chart
  refuses an `extraEnv` `NODE_OPTIONS` without it.
- **Large SQLite upgrades**: migrations block the process at the first start of a new version. The liveness probe
  tolerates 2 minutes; raise `livenessProbe.failureThreshold` for very large databases.

## Upgrading

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

1. **Secret key** — the previous chart shipped a default `KENER_SECRET_KEY` (`thesuperprivatekeytonotshare`). It was
   public: anyone could forge a session for any account. The chart now refuses it and generates a random key unless
   you set one. After the upgrade everybody logs in again and API keys created before must be re-created. If you
   had set your own key, it is kept (`kener.key` and `kener.keyFrom` still work, prefer `kener.secretKey` and
   `kener.existingSecret` + `kener.existingSecretKey`).
2. **SQLite data** — the previous chart had no persistence. If you mounted your own PVC on `/app/database` through
   `volumes`/`volumeMounts`, remove these entries and set `persistence.existingClaim: <your PVC>` (the chart refuses a
   second mount on `/app/database`). Without such a volume the data lived in the container and cannot be recovered.
   `/app/uploads` is gone: Kener 4 stores images in the database.
3. **External database** — `database.url` and `database.existingSecret` keep their meaning, but the URL now goes
   through a Secret and must start with `postgresql://` or `mysql://`. `database.secretKeys.url` becomes
   `database.existingSecretKey`, and `database.enabled: false` is simply an empty `database.url` (both old names still
   work). The old default URL (`postgresql://user:password@host:port/db`) is gone: SQLite is now the default.
4. **Redis** is mandatory: the bundled Valkey is deployed unless you set `redis.enabled: false` and `redis.external`.
5. **Image** — `docker.io/rajnandan1/kener:4.1.7-alpine` by default (`image.variant: debian` for the upstream
   default). The container always listens on 3000; `service.port` only changes the Service.
6. **Security context** — pods run as uid/gid 1000 (the image `node` user, as before) with a read-only root
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

## Requirements

Kubernetes: `>=1.27.0-0`

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
| image.tag | string | `""` | Image tag. Empty builds it from the chart appVersion, `kener.basePath` and `image.variant` (`4.1.10-alpine`, `4.1.10`, `4.1.10-status-alpine`...). |
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
| livenessProbe | object | `{"enabled":true,"failureThreshold":6,"periodSeconds":20,"timeoutSeconds":5}` | Liveness probe (`enabled: false` removes it). Without a handler, the chart adds `httpGet <basePath>/healthcheck` (always 200 while the server answers). Generous on purpose: large SQLite migrations block the process at the first start of a new version. |
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
| pingMonitors.enabled | bool | `false` | Make ICMP ping monitors work with all capabilities dropped: sets the safe sysctl `net.ipv4.ping_group_range` so `ping` can use unprivileged ICMP sockets, and keeps `NET_RAW` in the capability bounding set only, so the image's `ping` (which carries a `cap_net_raw` file capability) can still be executed. The process never holds `NET_RAW` (non-root, no privilege escalation), but the pod then matches the Pod Security Standard `baseline` instead of `restricted`. |
| podAnnotations | object | `{}` | Pod annotations. |
| podDisruptionBudget.enabled | bool | `false` | Create a PodDisruptionBudget for Kener (useful with 2+ replicas). |
| podDisruptionBudget.maxUnavailable | string | `nil` | Maximum unavailable pods (used instead of minAvailable when set). |
| podDisruptionBudget.minAvailable | int | `1` | Minimum available pods. |
| podLabels | object | `{}` | Pod labels. |
| podSecurityContext | object | `{"fsGroup":1000,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":1000,"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. The image user is `node` (uid/gid 1000). |
| priorityClassName | string | `""` | Priority class of the Kener pods. |
| proxy.httpProxy | string | `""` | `HTTP_PROXY` (stored in a Secret: it may carry credentials, percent-encoded). |
| proxy.httpsProxy | string | `""` | `HTTPS_PROXY` (stored in a Secret). |
| proxy.noProxy | string | `""` | `NO_PROXY`: hosts, `host:port`, `.suffix` (no CIDR). Add the in-cluster services your monitors reach directly. |
| readinessProbe | object | `{"enabled":true,"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":5}` | Readiness probe (`enabled: false` removes it). Without a handler, the chart adds `httpGet <basePath>/healthcheck?strict=1` (503 while the database or Redis is unreachable). |
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
| redis.image.tag | string | `"9.1.3-alpine"` | Valkey image tag. |
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
| resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"256Mi"}}` | Resource requests and limits (Kener recommends 1 vCPU / 1 GiB for real workloads). |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. |
| service.annotations | object | `{}` | Service annotations. |
| service.port | int | `3000` | Service port (the container always listens on 3000). |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | Service account annotations. |
| serviceAccount.automount | bool | `false` | Kener never talks to the Kubernetes API: the token is not mounted. |
| serviceAccount.create | bool | `true` | Create a dedicated service account. |
| serviceAccount.name | string | `""` | Service account name (generated when empty). |
| startupProbe | object | `{"enabled":true,"failureThreshold":60,"periodSeconds":5,"timeoutSeconds":5}` | Startup probe (`enabled: false` removes it). Without a handler, the chart adds `httpGet <basePath>/healthcheck`. |
| tests.image | string | `""` | Image used by `helm test` (defaults to the Kener image, which ships curl). |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. |
| updateStrategy | object | `{}` | Deployment update strategy. With SQLite and persistence the chart forces `Recreate`. |

## License

The chart is released under the MIT license. Kener is licensed under the MIT license, Valkey under the BSD-3-Clause
license.
