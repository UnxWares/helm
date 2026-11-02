# Laravel (generic) Helm Chart

![Version: 2026.11.5](https://img.shields.io/badge/Version-2026.11.5-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 12.x](https://img.shields.io/badge/AppVersion-12.x-informational?style=flat-square)
[![UWOSC: maintained](https://helm.unxwares.studio/assets/uwosc/mini-maintained.svg)](https://helm.unxwares.studio/#open-source)

Run **your own [Laravel](https://laravel.com) application image** on Kubernetes, packaged by UnxWares:
web pods (FrankenPHP, or PHP-FPM with an nginx sidecar), queue workers, scheduler and database
migrations, with hardened defaults. The chart ships no application: you build the image, the chart runs it.
The chart is maintained by UnxWares; it is not affiliated with the Laravel project.

## Features

- **Two runtimes**: `frankenphp` (the image serves HTTP itself, Octane compatible) or `fpm` (PHP-FPM + an unprivileged
  nginx sidecar sharing the public files of your image).
- **Queue workers** (`queue:work`), **scheduler** (CronJob running `schedule:run` every minute, or a `schedule:work`
  Deployment) and **migrations** before every install and upgrade (a hook Job, or an init container of the web pod
  with SQLite).
- **Secrets never in plain environment values**: APP_KEY, database/Redis/mail passwords, AWS keys and
  `laravel.secretEnv` live in a Secret (or your own existing Secrets) and are injected with `secretKeyRef`. APP_KEY is
  generated and kept across upgrades when you do not provide one.
- **Hardened by default**: non-root (uid 33), read-only root filesystem, every capability dropped, seccomp
  `RuntimeDefault`, no service account token. The directories Laravel writes to are volumes, seeded with what your
  image ships there.
- **Persistence** for `storage/app` and SQLite (PVC kept on uninstall), with the scheduling constraints a
  ReadWriteOnce volume needs.
- Ingress or Gateway API HTTPRoute, HPA, PodDisruptionBudget, NetworkPolicies (ingress + optional egress lockdown),
  `helm test`.

## Architecture

`<fullname>` is `<release>-laravel-generic`, or just `<release>` when the release name contains `laravel-generic`.

| Resource | Name | Created when | Content |
|----------|------|--------------|---------|
| Deployment (web) | `<fullname>` | always | Container `app` (FrankenPHP, or PHP-FPM); with `fpm`, an `nginx` sidecar; init containers `prepare`, then `migrate` (or `sqlite-init` without migrations) with SQLite, then `initContainers`; plus `sidecars`. |
| Deployment | `<fullname>-queue` | `workload.queueWorker.enabled` (default) | `workload.queueWorker.replicaCount` pods running `workload.queueWorker.command`. |
| CronJob or Deployment | `<fullname>-scheduler` | `workload.scheduler.enabled` (default) | `mode: cronjob`: a Job per `workload.scheduler.schedule` running `schedule:run`; `mode: deployment`: one `schedule:work` pod. |
| Job + Secret (hooks) | `<fullname>-migrations` | `workload.migrations.enabled` (default), not SQLite | `pre-install,pre-upgrade` hook; the Secret is a copy of the chart Secret. Both are deleted when the Job succeeds. |
| Service | `<fullname>` | always | `service.type` (ClusterIP), `service.port` (80) to the port `http` of the web pods. |
| Secret | `<fullname>` | when it has data | `app-key` (unless `laravel.key.existingSecret`), `db-password`, `redis-password`, `mail-password`, `aws-access-key-id`, `aws-secret-access-key` when given as values, one key per `laravel.secretEnv` entry. Kept on uninstall when APP_KEY is generated. |
| ConfigMap | `<fullname>-nginx` | `workload.runtime.type=fpm` | `nginx.conf` of the sidecar. |
| PersistentVolumeClaim | `<fullname>` | `persistence.enabled` (default), no `persistence.existingClaim` | `persistence.paths` and the SQLite directory; `helm.sh/resource-policy: keep`. |
| ServiceAccount | `<fullname>` | `serviceAccount.create` (default) | No RBAC, token not mounted. |
| Ingress / HTTPRoute | `<fullname>` | `ingress.enabled` / `httpRoute.enabled` | |
| HorizontalPodAutoscaler | `<fullname>` | `autoscaling.enabled` | Web Deployment only. |
| PodDisruptionBudget | `<fullname>` | `podDisruptionBudget.enabled` | Web pods only. |
| NetworkPolicy | `<fullname>`, `<fullname>-workers`, `<fullname>-egress` | `networkPolicy.enabled` (`-egress`: `networkPolicy.egress.enabled`) | See [NetworkPolicy](#networkpolicy). |
| Pod (test hook) | `<fullname>-test-http` | `helm test` | See [Testing](#testing). |

Volumes of the Laravel pods:

| Volume | Type | Mounted at | Holds |
|--------|------|------------|-------|
| `tmp` | emptyDir (`emptyDirSizeLimit`) | `/tmp` | temporary files |
| `writable` | emptyDir (`emptyDirSizeLimit`) | each `writablePaths` entry that is not on the PVC | framework cache, compiled views, file sessions, file logs, `bootstrap/cache` |
| `data` | PVC | each `persistence.paths` entry and the SQLite directory (web, queue and scheduler pods; not the migrations Job) | uploads (`storage/app`), SQLite database |
| `caddy` | emptyDir | `/data` and `/config` (FrankenPHP web container) | Caddy state and autosaved configuration |
| `public` | emptyDir | the public path, read-only in nginx (`fpm`) | copy of `public/` from the image |
| `nginx-tmp`, `nginx-config` | emptyDir (256Mi), ConfigMap | `/tmp`, `/etc/nginx/nginx.conf` of nginx (`fpm`) | nginx temporary files and configuration |

How it works:

- **Web pods** run the `app` container (FrankenPHP or PHP-FPM). With `fpm`, an `nginx` sidecar listens on 8080, serves
  the static files and passes PHP to `127.0.0.1:9000`. The `public/` directory is copied from your image into a volume
  mounted at the same path in nginx, so `SCRIPT_FILENAME` is valid in both containers; files of the `public` disk
  (`storage/app/public`) are served from the persistent volume when it holds them. The Service maps `service.port` to
  the HTTP port of the pod.
- **Writable paths** (`writablePaths`) are emptyDir volumes. The `prepare` init container seeds them with what the
  image contains (`bootstrap/cache/packages.php`, the `storage` skeleton...) and creates the directories Laravel
  expects. Paths listed in `persistence.paths` (or inside them) are stored on the PVC instead. `storage/app` is
  ephemeral unless persisted: use `persistence` or S3 for uploads.
- **Migrations** (`workload.migrations`) run in a `pre-install,pre-upgrade` hook Job, before the new pods roll out.
  Release resources do not exist yet at that point, so the Job uses its own copy of the Secret (deleted once it
  succeeds), no PVC, and the namespace default service account (or `serviceAccount.name` when
  `serviceAccount.create=false`). With SQLite, the single web pod creates the database file and migrates in an init
  container instead. Raise `helm --timeout` for long migrations.
- **Queue workers** get `terminationGracePeriodSeconds: 60` to finish their current job. **Scheduler**: a CronJob with
  `concurrencyPolicy: Forbid` and no retry (a retry would run the tasks of a past minute), or `mode: deployment` for a
  single `schedule:work` pod.
- **ReadWriteOnce volume**: the web Deployment keeps one replica with the `Recreate` strategy and the queue/scheduler
  pods are scheduled on the node of the web pod (required pod affinity). A ReadWriteMany volume, or
  `persistence.enabled=false` with S3, lifts both limits.
- **Graceful shutdown**: a 5 s `preStop` sleep on the web containers lets endpoints drain before
  FrankenPHP/PHP-FPM/nginx stop.
- **Logs** go to stderr by default (`laravel.log.channel`), visible with `kubectl logs`.
- **Environment**: every Laravel container (web, queue, scheduler, migrations) gets the same variables, rendered from
  `laravel.*` (see [Laravel settings](#laravel-settings)).

## Images

| Image | Default | Used by |
|-------|---------|---------|
| your application image | none: `image.repository` and `image.tag` (or `image.digest`) are required | `app`, `prepare`, `migrate`/`sqlite-init`, queue workers, scheduler, migrations Job |
| `docker.io/nginxinc/nginx-unprivileged` | `1.30.6-alpine-slim` | the `nginx` sidecar (`fpm` runtime only) and the `helm test` pod (unless `tests.image`) |

- The chart has no `imageProvider` value and UnxWares builds no image for it: the application image is yours, the
  nginx image is the upstream `nginx-unprivileged` (multi-architecture). UnxWares images
  ([images/](https://github.com/UnxWares/helm/tree/main/images), rebuilt twice a week and signed with cosign) are not
  used by this chart.
- `1.30.6-alpine-slim` is nginx without the optional njs, xslt, image-filter and geoip modules. If your
  `workload.nginx.config` loads one of them, set `workload.nginx.image.tag: 1.30.6-alpine`.
- Pin digests (they take precedence over the tags):

  ```yaml
  image:
    repository: registry.example.com/acme/shop
    digest: sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  workload:
    nginx:
      image:
        digest: sha256:5d8bb9437d74a600ec5dbf90c035451c724dc33eac8d3a71078f6f8612c345f6
  ```

- The [CVE watch issue](https://github.com/UnxWares/helm/issues?q=is%3Aissue+is%3Aopen+label%3Acve-watch) tracks
  the nginx image. Your application image is never scanned by this repository: scan it in your own pipeline.
- `tests.image` replaces the image of the `helm test` pod: it needs `wget` and must run as uid 101 with a read-only
  root filesystem.

## Requirements

Kubernetes: `>=1.27.0-0`

- Your application image (see [Requirements for your image](#requirements-for-your-image)), pullable by the cluster
  (`imagePullSecrets` for a private registry), built for the architecture of your nodes.
- Storage, with the default values: a default StorageClass, or `persistence.storageClass`, that provisions a 5 Gi
  ReadWriteOnce volume. Scaling the web pods with a persistent volume needs a ReadWriteMany storage class; without
  one, store files on S3 and use an external database.
- Database: SQLite on the PVC by default, or an external PostgreSQL, MySQL, MariaDB or SQL Server reachable from the
  pods. The chart deploys no database, no Redis and no mail server.
- An Ingress controller or a Gateway API implementation (`gateway.networking.k8s.io/v1` HTTPRoute) to expose the
  application, metrics-server for `autoscaling`, and a CNI that enforces NetworkPolicies for `networkPolicy`.
- Pod Security: with the default values every pod satisfies the `restricted` Pod Security Standard.

### Requirements for your image

| | FrankenPHP | PHP-FPM |
|---|---|---|
| Base image | [`dunglas/frankenphp`](https://frankenphp.dev/docs/docker/) (or Octane with FrankenPHP) | [`php:*-fpm`](https://hub.docker.com/_/php) |
| `appPath` (application directory) | `/app` (default) | usually `/var/www/html` |
| Listens on | `workload.runtime.frankenphp.port` (8000) | `workload.runtime.fpm.port` (9000, FastCGI) |

- The image must contain `/bin/sh` and `cp` (true for every official PHP image): an init container copies the content
  of the writable paths and of `public/` into volumes.
- Files must be readable by uid 33 (`www-data` in the Debian images; files are world-readable by default). Change
  `podSecurityContext` for another user.
- The root filesystem is read-only: everything is decided at build time (`composer install --no-dev`, `npm run build`,
  `php artisan storage:link`...). Run `php artisan optimize` at container start rather than at build time, since
  configuration comes from environment variables.
- Laravel 11+ exposes `/up`, used by the probes. Older applications: add a health route or change the probes.
- **FrankenPHP and capabilities**: the official binary carries the `cap_net_bind_service` file capability and cannot
  even start when the capability is missing from the bounding set. The chart keeps `NET_BIND_SERVICE` on the web
  container (the only capability allowed by the Pod Security Standards *restricted* profile). If your Dockerfile runs
  `setcap -r /usr/local/bin/frankenphp` (recommended), set `workload.runtime.frankenphp.keepNetBindService=false`.

## Installation

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
helm install shop unxwares/laravel-generic --namespace shop --create-namespace \
  --set image.repository=registry.example.com/acme/shop \
  --set image.tag=1.4.2
```

`image.repository` and `image.tag` (or `image.digest`) are required. The chart `appVersion` (`12.x`)
is the Laravel version the chart targets, never an image tag.

Charts are signed with the UnxWares Helm Charts OpenPGP key (fingerprint
`7902 E52E A435 EF27 C643  2E53 78D6 B532 C599 DA9B`, public key https://helm.unxwares.studio/pgp-public-key.asc).
To verify the package before installing:

```bash
curl -fsSL https://helm.unxwares.studio/pgp-public-key.asc | gpg --import
gpg --export 7902E52EA435EF27C6432E5378D6B532C599DA9B > ~/.gnupg/unxwares-helm.gpg
helm install shop unxwares/laravel-generic --namespace shop --create-namespace \
  --verify --keyring ~/.gnupg/unxwares-helm.gpg -f values.yaml
```

The minimal values are the image. With nothing else, the release runs FrankenPHP with SQLite and `storage/app` on a
5 Gi PVC, a queue worker and the scheduler CronJob, reachable inside the cluster only. A real install usually also
sets `laravel.name`, `laravel.url`, an Ingress or HTTPRoute, and, with GitOps tools, `laravel.key.existingSecret`
(see [Examples](#examples)).

To reach the application without exposing it:

```bash
kubectl -n shop port-forward svc/shop-laravel-generic 8080:80
```

then open http://127.0.0.1:8080 (`/up` answers when Laravel boots). The chart creates no application user: create
the first one the way your application does it (registration page, seeder, artisan command), for example
`kubectl -n shop exec -it deploy/shop-laravel-generic -c app -- php artisan db:seed --force`.

## Configuration

### Runtime: FrankenPHP or PHP-FPM

`workload.runtime.type: frankenphp` (default): the `app` container serves HTTP on
`workload.runtime.frankenphp.port` (8000). The chart sets `SERVER_NAME` for the stock FrankenPHP Caddyfile to
`workload.runtime.frankenphp.serverName`, or `:<port>` (plain HTTP on that port) when empty; keep it that way, TLS is
terminated in front of the pod. Laravel Octane runs through `command`:

```yaml
command: ["php", "artisan", "octane:frankenphp", "--host=0.0.0.0", "--port=8000", "--max-requests=500"]
```

`workload.runtime.type: fpm`: the `app` container runs PHP-FPM on `workload.runtime.fpm.port` (9000) and an nginx
sidecar serves HTTP on `workload.nginx.port` (8080). The HTTP probes (`livenessProbe`, `readinessProbe`,
`startupProbe`) then run on nginx, and PHP-FPM gets TCP probes (`workload.runtime.fpm.livenessProbe`,
`workload.runtime.fpm.readinessProbe`):

```yaml
image:
  repository: registry.example.com/acme/shop-fpm
  tag: "1.4.2"
appPath: /var/www/html
workload:
  runtime:
    type: fpm
  nginx:
    clientMaxBodySize: 64m
    workerProcesses: auto
```

The rendered `nginx.conf` sends errors to stderr and access logs to stdout, sets `server_tokens off`,
`X-Frame-Options: SAMEORIGIN` and `X-Content-Type-Options: nosniff`, caches `/build/` (Vite assets) for a year,
denies dotfiles except `/.well-known`, and executes only `index.php`. `workload.nginx.config` replaces the whole
`server { }` block: it must listen on `workload.nginx.port`, use the public path as `root` and pass PHP to
`127.0.0.1:<workload.runtime.fpm.port>`. `workload.nginx.ipv6` adds an IPv6 listener (dual-stack clusters only).

### Application paths and writable directories

`appPath` is the application directory of the image, `publicPath` the public directory (default
`<appPath>/public`). `writablePaths` (relative to `appPath` or absolute) are emptyDir volumes, seeded from the image
when `seedWritablePaths` is true; anything else outside `/tmp` is read-only. A list in your values replaces the
default list, so repeat its entries:

```yaml
writablePaths:            # the list replaces the default one: keep its entries
  - storage/framework
  - storage/logs
  - storage/app
  - bootstrap/cache
  - storage/tenants       # written by the application at run time
```

`emptyDirSizeLimit` (1Gi) caps each emptyDir (`/tmp`, writable paths, public copy, Caddy state); `prepareResources`
sets the resources of the `prepare` init container.

### Laravel settings

`laravel.*` values become environment variables of every Laravel container (`laravel.name` is `APP_NAME`,
`laravel.env` is `APP_ENV`, `laravel.log.level` is `LOG_LEVEL`...: the values table names each variable). Empty
values are not rendered, so the defaults of your `config/*.php` files apply. `laravel.extraEnv` is rendered last and
overrides the chart variables.

```yaml
laravel:
  name: Shop
  url: https://shop.example.com
  locale:
    default: fr
    fallback: en
    faker: fr_FR
  log:
    level: warning
```

`APP_URL` is `laravel.url`, or, when it is empty, derived from the first Ingress host (`https` when that host is
listed in `ingress.tls`). It is not derived from an HTTPRoute: set `laravel.url` there. `laravel.debug` sets
`APP_DEBUG`; never enable it in production.

### Database

**SQLite** (default, `laravel.database.connection: sqlite`): the file is `laravel.database.database`, by default
`storage/database/database.sqlite`, in a dedicated directory stored on the PVC. It requires `persistence.enabled`
and a single web replica (without `autoscaling`), and its directory cannot be `appPath`, `database/` or the public
directory (rendering fails otherwise). The web pod creates the file and runs the migrations in an init container.

**PostgreSQL, MySQL, MariaDB, SQL Server** (`pgsql`, `mysql`, `mariadb`, `sqlsrv`): `laravel.database.host` and a
password are required. The password is stored in the chart Secret, or read from `laravel.database.existingSecret`:

```yaml
persistence:
  enabled: false
laravel:
  database:
    connection: mysql
    host: mysql.databases.svc
    database: shop
    username: shop
    password: change-me            # stored in the chart Secret
```

With `existingSecret`, every entry of `laravel.database.secretKeys` (host, port, database, username, password) is read
from that Secret and overrides the plain value. The default key names (`database-host`, `database-password`...) must
exist in the Secret; set an entry to `""` to keep the plain value instead:

```yaml
persistence:
  enabled: false
laravel:
  database:
    connection: pgsql
    host: shop-db-rw.databases.svc
    port: 5432
    database: shop
    username: shop
    existingSecret: shop-db        # holds only the password, in key "password"
    secretKeys:
      host: ""                     # "" keeps the plain value above
      port: ""
      database: ""
      username: ""
      password: password
```

A CloudNativePG application Secret can be used directly, see [Examples](#examples). `laravel.database.enabled=false`
renders no `DB_*` variable at all.

### Cache, sessions, queues and Redis

`laravel.session.driver`, `laravel.cache.store` and `laravel.queue_connection` default to `database` (the tables come
from the default Laravel migrations). With several web replicas, use a shared store (database or Redis); `file`
sessions and caches live in the emptyDir of each pod. `php artisan down` with the default `file` maintenance driver
only affects one pod: use `laravel.maintenance.driver: cache` with a shared store. `laravel.redis.enabled` renders the
`REDIS_*` variables; `laravel.redis.existingSecret` works like the database one:

```yaml
laravel:
  session:
    driver: redis
  cache:
    store: redis
  queue_connection: redis
  maintenance:
    driver: cache
    store: redis
  redis:
    enabled: true
    host: shop-redis.databases.svc
    existingSecret: shop-redis
    secretKeys:
      host: ""
      port: ""
      password: password
```

`laravel.memcached.host` sets `MEMCACHED_HOST`.

### Files: persistence and S3

`persistence.enabled` (default) stores `persistence.paths` (default `storage/app`) and the SQLite directory on one
PVC, each path in its own sub-directory, mounted in the web, queue worker and scheduler pods. Settings:
`persistence.size` (5Gi), `persistence.storageClass` (`"-"` renders `storageClassName: ""`, which disables dynamic
provisioning), `persistence.accessModes`, `persistence.annotations`, `persistence.existingClaim`.

- **ReadWriteOnce** (default): one web replica, `Recreate` strategy, queue and scheduler pods on the node of the web
  pod. `ReadWriteOncePod` only works when the web pod is the only one to mount the volume (queue workers and
  scheduler disabled).
- **ReadWriteMany**: no such limit.

  ```yaml
  persistence:
    enabled: true
    storageClass: cephfs
    accessModes: [ReadWriteMany]
    size: 20Gi
    paths:
      - storage/app
  ```

- **S3** (`laravel.aws.*`, `laravel.filesystem_disk: s3`): files go to a bucket. With an external database too,
  `persistence.enabled=false` removes the PVC and its constraints. The access keys are stored in the chart Secret or
  read from `laravel.aws.existingSecret`:

  ```yaml
  laravel:
    filesystem_disk: s3
    aws:
      enabled: true
      bucket: shop
      region: us-east-1
      endpoint: https://minio.example.com
      url: https://minio.example.com/shop
      use_path_style_endpoint: true
      existingSecret: shop-s3        # keys aws-access-key-id and aws-secret-access-key
      secretKeys:
        region: ""
        bucket: ""
        use_path_style_endpoint: ""
  ```

With the `fpm` runtime, files of the `public` disk (`storage/app/public`, behind the `public/storage` link) are
served by nginx from the PVC when a path of `persistence.paths` contains them.

### Email

`laravel.mail.enabled` renders the `MAIL_*` variables; the password is stored in the chart Secret or read from
`laravel.mail.existingSecret`:

```yaml
laravel:
  mail:
    enabled: true
    mailer: smtp
    scheme: smtps
    host: smtp.example.com
    port: 465
    username: shop@example.com
    existingSecret: shop-smtp      # holds only the password, in key "password"
    secretKeys:
      host: ""
      port: ""
      username: ""
      password: password
    from:
      address: shop@example.com
```

`MAIL_FROM_NAME` defaults to `$(APP_NAME)`, expanded by Kubernetes.

### Secrets and APP_KEY

Secret values reach the containers only through `secretKeyRef`: the chart Secret `<fullname>` holds the values you
give (`laravel.database.password`, `laravel.redis.password`, `laravel.mail.password`, `laravel.aws.access_key_id`,
`laravel.aws.secret_access_key`, `laravel.secretEnv`), or the containers read your own Secrets (`existingSecret` of
each section, `laravel.extraEnvFrom`). Values given in `values.yaml` are also stored by Helm in its release Secret
(`sh.helm.release.v1.*`): prefer existing Secrets for production credentials.

```yaml
laravel:
  secretEnv:                       # stored in the chart Secret, injected with secretKeyRef
    STRIPE_SECRET: sk_live_xxx
  extraEnvFrom:                    # or bring your own Secret
    - secretRef:
        name: shop-env
```

**APP_KEY** comes from `laravel.key.existingSecret` (key `laravel.key.existingSecretKey`), else from
`laravel.key.value`, else it is generated (`base64:` + 32 random bytes). A generated key is read back from the
release Secret on every upgrade, and that Secret is kept on `helm uninstall` (`helm.sh/resource-policy: keep`) so a
reinstall of the same release in the same namespace reuses it. Tools that render templates offline (Argo CD...)
cannot read it back and would rotate it on every sync: set `laravel.key.value` or `laravel.key.existingSecret`.
Losing APP_KEY makes encrypted data and sessions unreadable.

```bash
kubectl -n shop create secret generic shop-app-key --from-literal=key="base64:$(openssl rand -base64 32)"
```

```yaml
laravel:
  key:
    existingSecret: shop-app-key
    existingSecretKey: key
```

Every Laravel pod carries a `checksum/secret` annotation computed from the secret values of the chart, so changing
them restarts the pods. Changes made inside your own existing Secrets do not: run `kubectl rollout restart` afterwards.

### Queue workers

`workload.queueWorker.*`: `replicaCount`, `command`, `terminationGracePeriodSeconds` (keep it above your longest job),
`resources`, an optional `livenessProbe`, and scheduling overrides (see [Scheduling](#scheduling)). The workers do
not restart by themselves when the code changes: a `helm upgrade` with a new image tag rolls them out.

```yaml
workload:
  queueWorker:
    replicaCount: 2
    command: ["php", "artisan", "queue:work", "--queue=high,default", "--tries=3", "--max-time=3600"]
    terminationGracePeriodSeconds: 120
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        memory: 1Gi
```

### Scheduler

`workload.scheduler.mode: cronjob` (default) creates a CronJob running `workload.scheduler.command` on
`workload.scheduler.schedule`, with `concurrencyPolicy` (`Forbid`: a minute is skipped while the previous run is still
going, use `runInBackground()` for long tasks), `startingDeadlineSeconds`, `backoffLimit` (0),
`ttlSecondsAfterFinished` and the history limits. `mode: deployment` runs one pod with `workload.scheduler.workCommand`
(`schedule:work`) instead of a pod per minute:

```yaml
workload:
  scheduler:
    mode: deployment               # one schedule:work pod instead of a pod per minute
```

### Migrations

`workload.migrations.command` (`php artisan migrate --force`) runs before every install and upgrade (see
[Architecture](#architecture)). `backoffLimit` and `activeDeadlineSeconds` bound the Job; a long migration also needs
a larger `helm --timeout` (5 minutes by default). `workload.migrations.enabled=false` skips them (with SQLite the init
container then only creates the database file).

```yaml
workload:
  migrations:
    activeDeadlineSeconds: 1800    # also run helm upgrade with --timeout 35m
    backoffLimit: 0
```

### Exposure and TLS

The Service exposes `service.port` (80) on the `http` port of the web pods (FrankenPHP, or nginx with `fpm`);
`service.type` and `service.annotations` are configurable. The pods serve plain HTTP: terminate TLS at the Ingress or
the Gateway.

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    nginx.ingress.kubernetes.io/proxy-body-size: 16m
  hosts:
    - host: shop.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: shop-tls
      hosts:
        - shop.example.com
```

```yaml
laravel:
  url: https://shop.example.com     # not derived from the HTTPRoute
httpRoute:
  enabled: true
  parentRefs:
    - name: public-gateway
      namespace: gateway-system
      sectionName: https
  hostnames:
    - shop.example.com
```

Behind a proxy, Laravel must trust it to generate `https` URLs: configure trusted proxies in your application
(`$middleware->trustProxies(at: '*')` in `bootstrap/app.php` on Laravel 11+).

### Resources and scaling

`resources` applies to the web container; `workload.nginx.resources`, `workload.queueWorker.resources`,
`workload.scheduler.resources`, `workload.migrations.resources` and `prepareResources` to the others. The web
Deployment scales with `replicaCount` or `autoscaling.*` (CPU target), with `podDisruptionBudget.*`,
`updateStrategy` (ignored with a ReadWriteOnce volume, which forces `Recreate`) and `topologySpreadConstraints` (web
pods only). Scaling needs an external database and no
ReadWriteOnce volume (rendering fails otherwise):

```yaml
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 6
podDisruptionBudget:
  enabled: true
  maxUnavailable: 1
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: laravel-generic
        app.kubernetes.io/instance: shop
        app.kubernetes.io/component: web
```

### Scheduling

`nodeSelector`, `tolerations`, `affinity` and `priorityClassName` apply to every pod. `workload.queueWorker`,
`workload.scheduler` and `workload.migrations` each have their own `nodeSelector`, `tolerations` and `affinity`,
which replace the top-level value when set. With a ReadWriteOnce volume, a required pod affinity to the web pods is
added to the queue and scheduler pods.

```yaml
nodeSelector:
  kubernetes.io/arch: amd64
tolerations:
  - key: dedicated
    operator: Equal
    value: web
    effect: NoSchedule
workload:
  queueWorker:
    nodeSelector:                  # replaces the top-level nodeSelector for the queue workers
      node-role.example.com/batch: "true"
```

### NetworkPolicy

`networkPolicy.enabled` creates:

- `<fullname>`: the web pods accept traffic on their `http` port only, from `networkPolicy.allowedFrom` and the pods
  of the release (any source when `allowedFrom` is empty);
- `<fullname>-workers`: the queue worker, scheduler and migrations pods accept no incoming traffic;
- with `networkPolicy.egress.enabled`, `<fullname>-egress`: every pod of the release (the migrations Job and the
  `helm test` pod included) may only reach DNS, the pods of the release and `networkPolicy.egress.rules`. List the
  database, Redis, SMTP, S3 and external APIs there.

```yaml
networkPolicy:
  enabled: true
  allowedFrom:                     # who may reach the web pods
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
  egress:
    enabled: true                  # DNS and release pods are always allowed
    rules:
      - to:
          - namespaceSelector:
              matchLabels:
                kubernetes.io/metadata.name: databases
        ports:
          - port: 5432
            protocol: TCP
```

### Monitoring

The chart creates no metrics endpoint or ServiceMonitor. Logs go to stderr (`laravel.log.channel`), and nginx writes
its access log to stdout. The probes call `/up`; `tests.path` sets the path checked by `helm test`.

### Extra containers, volumes, environment and labels

`initContainers` (after the chart ones) and `sidecars` are added to the web pods. `extraVolumes` are added to every
Laravel pod and `extraVolumeMounts` to every Laravel container (`workload.nginx.extraVolumeMounts` for nginx).
`laravel.extraEnv`/`laravel.extraEnvFrom` go to every Laravel container, `podAnnotations`/`podLabels` to every pod,
`commonLabels` to every resource and pod. `command`, `args`, `lifecycle` and `terminationGracePeriodSeconds` set the
web container.

```yaml
extraVolumes:
  - name: db-ca
    configMap:
      name: db-ca
extraVolumeMounts:
  - name: db-ca
    mountPath: /etc/ssl/db
    readOnly: true
laravel:
  extraEnv:
    - name: SANCTUM_STATEFUL_DOMAINS
      value: shop.example.com
podAnnotations:
  backup.velero.io/backup-volumes: data
commonLabels:
  team: shop
```

## Examples

The snippets below are values files; add `image.repository` and `image.tag` to those that do not set them.

### FrankenPHP with SQLite (defaults)

A single web replica with the SQLite database and `storage/app` on a PVC; migrations run in an init container of the
web pod.

```yaml
image:
  repository: registry.example.com/acme/shop
  tag: "1.4.2"
laravel:
  name: Shop
  url: https://shop.example.com
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: shop.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: shop-tls
      hosts:
        - shop.example.com
```

### PHP-FPM + nginx, PostgreSQL, Redis and S3, scaled out

```yaml
image:
  repository: registry.example.com/acme/shop-fpm
  tag: "1.4.2"
appPath: /var/www/html
workload:
  runtime:
    type: fpm
  scheduler:
    mode: deployment        # schedule:work, no pod per minute
replicaCount: 3
persistence:
  enabled: false            # files on S3: no shared volume needed
podDisruptionBudget:
  enabled: true
laravel:
  key:
    existingSecret: shop-app-key   # key: key
  database:
    connection: pgsql
    # CloudNativePG application secret: host, port, dbname, user, password
    existingSecret: shop-db-app
    secretKeys:
      host: host
      port: port
      database: dbname
      username: user
      password: password
  redis:
    enabled: true
    host: shop-redis.databases.svc
    existingSecret: shop-redis
    secretKeys:
      host: ""                     # keep the plain value
      port: ""
      password: password
  session:
    driver: redis
  cache:
    store: redis
  queue_connection: redis
  filesystem_disk: s3
  aws:
    enabled: true
    bucket: shop
    region: eu-west-3
    existingSecret: shop-s3        # aws-access-key-id, aws-secret-access-key
    secretKeys:
      region: ""
      bucket: ""
      use_path_style_endpoint: ""
```

### Persist the whole `storage` directory

```yaml
persistence:
  enabled: true
  accessModes: [ReadWriteMany]   # lets the web Deployment scale and roll out without downtime
  paths:
    - storage
```

Writable paths inside a persisted path (`storage/framework`, `storage/logs`...) then live on the volume too.

### Laravel Octane (FrankenPHP worker mode)

```yaml
command: ["php", "artisan", "octane:frankenphp", "--host=0.0.0.0", "--port=8000", "--max-requests=500"]
```

### Lock down the network

```yaml
networkPolicy:
  enabled: true
  allowedFrom:                     # who may reach the web pods
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
  egress:
    enabled: true                  # DNS and release pods are always allowed
    rules:
      - to:
          - namespaceSelector:
              matchLabels:
                kubernetes.io/metadata.name: databases
        ports:
          - port: 5432
            protocol: TCP
```

### More secrets

```yaml
laravel:
  secretEnv:                       # stored in the chart Secret, injected with secretKeyRef
    STRIPE_SECRET: sk_live_xxx
  extraEnvFrom:                    # or bring your own Secret
    - secretRef:
        name: shop-env
```

## Security

What the chart does by default:

- **Users**: every pod runs as non-root, uid/gid 33 with `fsGroup: 33` for the Laravel containers
  (`podSecurityContext`), uid 101 for the nginx sidecar and the `helm test` pod. Seccomp profile `RuntimeDefault`.
- **Containers**: `allowPrivilegeEscalation: false`, read-only root filesystem, every capability dropped. The only
  exception is `NET_BIND_SERVICE`, added back to the FrankenPHP web container while
  `workload.runtime.frankenphp.keepNetBindService` is true (see
  [Requirements for your image](#requirements-for-your-image)). The pods satisfy the `restricted` Pod Security
  Standard.
- **Service accounts**: the chart's service account has no RBAC and its token is not mounted
  (`serviceAccount.automount=false`, also set on every pod). The migrations Job uses the namespace default service
  account, without token either.
- **Secrets**: only through `secretKeyRef` and `envFrom`, never as plain values in the pod spec (see
  [Secrets and APP_KEY](#secrets-and-app_key)). The copy used by the migrations hook is deleted when the Job succeeds.
- **Exposure**: the Service publishes the HTTP port of the web pods only. NetworkPolicies are off by default
  (`networkPolicy.enabled`).

Caveats:

- PHP-FPM listens on port 9000 on every pod address in the official images. That port is not in the Service, but any
  pod of the cluster can send FastCGI requests to it, which lets it run PHP code in your application. With the `fpm`
  runtime, enable `networkPolicy` (the web pods then accept their `http` port only), or make PHP-FPM listen on
  `127.0.0.1:9000` in your image.
- nginx only executes `index.php`, like the configuration of the Laravel documentation: any other `.php` file under
  `public/` is served as a static file. Keep PHP code out of `public/`.
- Values given in `values.yaml` (passwords, `laravel.secretEnv`) are also readable in the Helm release Secret by
  anyone who can read Secrets in the namespace: use existing Secrets for production credentials.
- `laravel.debug: true` shows stack traces and configuration to visitors; the chart prints a warning in its notes.
- The chart cannot harden your application image: its base image, PHP extensions and dependencies are yours to keep
  up to date and scan. The CVE watch of this repository only covers the nginx image.

## Testing

On every pull request, the repository CI runs for this chart:

- `helm lint --strict` with Helm 3 (v3.22.1) and Helm 4 (v4.3.1), on the default values (in lint mode, the
  required-value checks only log a message) and on each `ci/*-values.yaml`: `ci/default-values.yaml` (FrankenPHP with
  `dunglas/frankenphp:1-php8.4-alpine` as a placeholder image, SQLite, NetworkPolicy) and `ci/fpm-values.yaml`
  (`php:8.4-fpm-alpine` placeholder, PHP-FPM + nginx, PostgreSQL with an existing Secret, Redis, S3, PDB, Ingress,
  NetworkPolicy with egress rules);
- kubeconform (strict) for Kubernetes 1.31.0 and 1.34.0 on the renders of the `ci/` files (the default values cannot
  render without an image);
- the Artifact Hub metadata lint (`ah lint`), and a check that `README.md` and `values.schema.json` match what
  `generate-schemas.sh` produces.

When the pull request changes the chart, `ct lint` (chart-testing: lint, YAML lint, version increment check) runs as
well. `ct install` does not install this chart: the `ci/` files only use placeholder images, since the chart needs a
Laravel application image. The end-to-end test installs it instead.

**End-to-end test** (`.github/workflows/e2e.yaml`, on pull requests that touch the chart, every push to main and
every Tuesday). A Laravel 13 test application, `.github/e2e/laravel-app` (the laravel/laravel skeleton at a pinned
commit, a committed `composer.lock`, a few routes, a queued job, a scheduled task and a migration), is built in CI for
both runtimes and never published. Two releases run in a namespace that enforces the `restricted` Pod Security
Standard:

- FrankenPHP (official image, `/app`), SQLite on the persistent volume, scheduler CronJob, NetworkPolicy
  (`ci/default-values.yaml`);
- PHP-FPM (official Alpine image, `appPath: /var/www/html`) behind the nginx sidecar, an external PostgreSQL with the
  password in an existing Secret, `schedule:work` Deployment, NetworkPolicy.

After `helm test`, `.github/scripts/laravel-generic-e2e.sh` checks through the Service: the runtime that answers
(PHP SAPI, and with `fpm` the nginx headers and the static files of the public copy), uid 33 on a read-only root
filesystem, the generated APP_KEY of the chart Secret in the web, migration, queue worker and scheduler pods, where
the migrations ran (init container of the web pod with SQLite, hook Job otherwise, the Job and its Secret copy gone
afterwards), a note written to the database and read back with its encrypted copy, a session counter (database store,
encrypted cookie, Blade view), a cache value, a queued job run by a queue worker pod that writes to `storage/app` (read
back by the web pod; the public disk served under `/storage/`), the every-minute scheduled task, and with `fpm` that
another pod reaches nginx but not PHP-FPM. Both releases are then uninstalled and installed again: the kept Secret and
PVC must give back the same APP_KEY, the note (still decrypted), the session, the files and the SQLite database.

Not installed in CI (the unit tests render some of them): Laravel Octane, Redis, MySQL, MariaDB and SQL Server, S3,
Ingress and HTTPRoute, the HPA, the egress NetworkPolicy, several nodes, and upgrades from a previous chart version.

The test pod, `<fullname>-test-http`, runs `tests.image` (default: the nginx image) as uid 101 with a read-only root
filesystem and no capabilities, and requests `http://<fullname>:<service.port><tests.path>` (`/up`) with `wget`
(10 s timeout). It succeeds when the Service reaches a ready web pod and Laravel answers with a success status. After
an install:

```bash
helm test shop --namespace shop --logs
```

Unit tests (`tests/*_test.yaml`, [helm-unittest](https://github.com/helm-unittest/helm-unittest), run by
`.github/workflows/unit.yaml` on pull requests, every push to main and every Tuesday) render the chart without a
cluster and check the message of every required value, the security contexts and writable paths, FrankenPHP and
PHP-FPM + nginx (ports, probes, nginx configuration), the env with credentials through `secretKeyRef` only, the
`APP_KEY` generated once and kept, the migrations hook, queue workers and scheduler, NetworkPolicy, HPA and PDB, and
the examples of this README.

## Operations

### Backup and restore

- **APP_KEY**: keep a copy outside the cluster; without it, encrypted data cannot be read back.

  ```bash
  kubectl -n shop get secret shop-laravel-generic -o jsonpath='{.data.app-key}' | base64 -d
  ```

- **External database**: use its own backups (pg_dump, CloudNativePG backups...).
- **Files**: snapshot the PVC with your storage tools (VolumeSnapshot, Velero...), or copy a persisted path (here
  `storage/app` with `appPath: /app`):

  ```bash
  kubectl -n shop exec deploy/shop-laravel-generic -c app -- tar czf - -C /app/storage/app . > shop-storage-app.tgz
  ```

  With S3, use the versioning or replication of the bucket.
- **SQLite**: a consistent copy, taken while the application runs (`VACUUM INTO`, through `pdo_sqlite`):

  ```bash
  kubectl -n shop exec -i deploy/shop-laravel-generic -c app -- php <<'EOF'
  <?php
  $db = new PDO('sqlite:' . getenv('DB_DATABASE'));
  $db->prepare('VACUUM INTO ?')->execute(['/tmp/backup.sqlite']);
  EOF
  kubectl -n shop exec deploy/shop-laravel-generic -c app -- cat /tmp/backup.sqlite > shop-backup.sqlite
  kubectl -n shop exec deploy/shop-laravel-generic -c app -- rm /tmp/backup.sqlite
  ```

  To restore, stop the writers first (queue workers and scheduler; with `workload.scheduler.mode: deployment`, scale
  `deploy/shop-laravel-generic-scheduler` instead of suspending the CronJob), write the file back, then restart:

  ```bash
  kubectl -n shop scale deploy/shop-laravel-generic-queue --replicas=0
  kubectl -n shop patch cronjob shop-laravel-generic-scheduler -p '{"spec":{"suspend":true}}'
  kubectl -n shop exec -i deploy/shop-laravel-generic -c app -- sh -c 'cat > "$DB_DATABASE"' < shop-backup.sqlite
  kubectl -n shop rollout restart deploy/shop-laravel-generic
  kubectl -n shop patch cronjob shop-laravel-generic-scheduler -p '{"spec":{"suspend":false}}'
  kubectl -n shop scale deploy/shop-laravel-generic-queue --replicas=1
  ```

### Scaling limits

- SQLite: one web replica, no `autoscaling`.
- ReadWriteOnce volume: one web replica (`Recreate`, so a short downtime on each rollout), queue and scheduler pods on
  the same node. Queue workers can still scale (`workload.queueWorker.replicaCount`).
- The scheduler always runs once (one CronJob run at a time, or one `schedule:work` pod).
- With several web replicas, sessions, cache and maintenance mode need a shared store, and files need S3 or a
  ReadWriteMany volume. `bootstrap/cache` and `storage/framework` are per pod: `php artisan optimize:clear` in one pod
  does not clear the others (restart them with `kubectl rollout restart`).

### Logs and useful commands

```bash
kubectl -n shop logs deploy/shop-laravel-generic -c app
kubectl -n shop logs deploy/shop-laravel-generic -c nginx            # fpm runtime
kubectl -n shop logs deploy/shop-laravel-generic -c prepare          # init container
kubectl -n shop logs deploy/shop-laravel-generic-queue
kubectl -n shop logs -l app.kubernetes.io/instance=shop,app.kubernetes.io/component=scheduler --tail=50
kubectl -n shop exec -it deploy/shop-laravel-generic -c app -- php artisan about
kubectl -n shop create job --from=cronjob/shop-laravel-generic-scheduler schedule-now   # cronjob mode
```

## Upgrading

A `helm upgrade` with a new `image.tag` runs the migrations Job first; the web, queue and scheduler pods roll out only
when it succeeds. With SQLite, the new web pod migrates in its init container.

### To 2026.11.4

An empty `workload.nginx.image.tag` or `workload.nginx.image.repository` now fails rendering instead of giving the
nginx sidecar and the `helm test` pod an image without a tag. If your values set one of them to `""`, remove it (the
default applies) or set `workload.nginx.image.digest`.

### To 2026.10.2

The nginx sidecar image is now `nginxinc/nginx-unprivileged:1.30.6-alpine-slim` (no njs, xslt, image-filter or geoip
modules). If your `workload.nginx.config` loads one of these modules, set `workload.nginx.image.tag: 1.30.6-alpine`.

### From 2026.2.x to 2026.10.1

This release fixes a chart that could not work as published (invalid image, unused runtime ports, unreachable nginx, failing migrations) and contains **breaking changes**:

1. **Required values**: set `image.repository` **and** `image.tag` (or `image.digest`): the tag no longer defaults to `12.x`.
2. **Selectors changed** (standard `app.kubernetes.io/component` labels), and the service account was a hook resource that Helm cannot adopt. Before `helm upgrade`, delete them (the new ones are created by the upgrade):
   ```bash
   kubectl -n <namespace> delete deployment <fullname> <fullname>-queue
   kubectl -n <namespace> delete serviceaccount <fullname>
   ```
3. **nginx** is now a sidecar used with `workload.runtime.type=fpm` (`workload.nginx.enabled`, `replicaCount` and `service` are gone; the old Deployment/Service are removed). `workload.nginx.config` still replaces the `server { }` block, which must now listen on 8080 and pass PHP to `127.0.0.1:9000`. The image is `nginxinc/nginx-unprivileged` (the official `nginx` image cannot run unprivileged).
4. **Hardened security context**: non-root uid 33, read-only root filesystem. Anything your application writes outside `writablePaths`, `persistence.paths` and `/tmp` must be added to these lists.
5. **SQLite** now requires `persistence.enabled` and a dedicated directory; the default file is `storage/database/database.sqlite`. A database under `database/` would hide the migrations and is refused.
6. **Credentials**: the `user`/`password` database defaults are gone; non SQLite connections require `laravel.database.host` and a password (or `existingSecret`).
7. `volumes`/`volumeMounts` are renamed `extraVolumes`/`extraVolumeMounts` (the old names still work, deprecated).
8. Defaults changed: `LOG_CHANNEL=stderr`, `MAIL_FROM_NAME`/`VITE_APP_NAME` use `$(APP_NAME)`, the S3 region is exported as `AWS_DEFAULT_REGION`, empty settings (APP_URL, ports...) are no longer exported so Laravel's defaults apply.

## Troubleshooting

- **`helm install` fails before creating anything**: the chart refuses values that cannot work. The message names
  the fix: `image.repository is required`, `image.tag (or image.digest) is required`, `laravel.database.host is
  required`, `laravel.database.password or laravel.database.existingSecret (+ secretKeys.password) is required`,
  `SQLite supports a single web replica`, `persistence uses a ReadWriteOnce volume`, `the SQLite file needs a
  dedicated directory`, `persistence.paths is empty`, `workload.nginx.image.tag (or workload.nginx.image.digest) is
  required`. `helm lint` does not catch these: use `helm template`.
- **Migrations failed** (`pre-install`/`pre-upgrade` hook error): the Job and its Secret stay for inspection, the
  previous pods keep running.

  ```bash
  kubectl -n shop logs job/shop-laravel-generic-migrations
  kubectl -n shop describe job shop-laravel-generic-migrations
  ```

  `DeadlineExceeded` or a Helm timeout: raise `workload.migrations.activeDeadlineSeconds` and `helm --timeout`.
  Connection refused with `networkPolicy.egress.enabled`: add the database to `networkPolicy.egress.rules`.
- **`CreateContainerConfigError`**: a referenced Secret or key does not exist
  (`kubectl -n shop describe pod <pod>`). With an `existingSecret`, the default `secretKeys` names must exist in it,
  or be set to `""`. The Secrets of `existingSecret` must exist before the install, since the migrations Job reads
  them.
- **`Read-only file system` or `Permission denied` in the logs**: the application writes outside `writablePaths`,
  `persistence.paths` and `/tmp`; add the path to `writablePaths`. `warning: some files of ... could not be copied` in
  the `prepare` logs: files of the image are not readable by uid 33.
- **FrankenPHP does not start (`operation not permitted`)**: the binary carries the `cap_net_bind_service` file
  capability and `workload.runtime.frankenphp.keepNetBindService` is false; set it to true or strip the capability
  in the image.
- **Probes fail on `/up`**: Laravel older than 11, or a routing change: add a health route and set the probe paths
  and `tests.path`. With `fpm`, a `File not found` or `Primary script unknown` answer means `appPath` or `publicPath`
  does not match the image. nginx failing with `Address family not supported`: set `workload.nginx.ipv6=false`.
- **Queue or scheduler pods `Pending`**: with a ReadWriteOnce volume they must run on the node of the web pod; check
  that the web pod is scheduled and that this node has room (`kubectl -n shop describe pod <pod>`).
- **`http://` links or redirect loops behind the ingress**: Laravel does not trust the proxy headers (see
  [Exposure and TLS](#exposure-and-tls)), or `laravel.url` is not set with an HTTPRoute.
- **Users logged out, `The MAC is invalid`**: APP_KEY changed, typically through GitOps rendering; pin it (see
  [Secrets and APP_KEY](#secrets-and-app_key)).
- **Node drain blocked**: `podDisruptionBudget.enabled` with a single web replica and `minAvailable: 1`.
- **`helm test` fails**: `helm test shop -n shop --logs`; with `networkPolicy.allowedFrom` set, the test pod is
  allowed as a pod of the release.

## Uninstalling

```bash
helm uninstall shop --namespace shop
```

What stays in the namespace:

- the PVC `<fullname>` created by the chart (`helm.sh/resource-policy: keep`), with the uploaded files and the SQLite
  database. A PVC given with `persistence.existingClaim` is never touched by the chart;
- the Secret `<fullname>` when APP_KEY was generated (`helm.sh/resource-policy: keep`). A reinstall with the same
  release name in the same namespace takes both over again and reuses the key;
- hook resources that did not succeed: the `<fullname>-migrations` Job and Secret, the `<fullname>-test-http` pod
  (`helm uninstall` does not remove hook resources);
- your own Secrets (`existingSecret`, `extraEnvFrom`) and external services.

To start from scratch (irreversible: the files, the SQLite database and APP_KEY are lost):

```bash
kubectl -n shop delete pvc shop-laravel-generic
kubectl -n shop delete secret shop-laravel-generic
kubectl -n shop delete job,secret -l app.kubernetes.io/instance=shop,app.kubernetes.io/component=migrations
kubectl -n shop delete pod shop-laravel-generic-test-http --ignore-not-found
```

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity rules. |
| appPath | string | `"/app"` | Directory of the Laravel application in the image (its WORKDIR): `/app` for FrankenPHP images, usually `/var/www/html` for the official PHP-FPM images. |
| args | list | `[]` | Arguments of the web container. |
| autoscaling.enabled | bool | `false` | Enable the web HorizontalPodAutoscaler (not with SQLite or a ReadWriteOnce volume). |
| autoscaling.maxReplicas | int | `10` | Maximum replicas. |
| autoscaling.minReplicas | int | `2` | Minimum replicas. |
| autoscaling.targetCPUUtilizationPercentage | int | `80` | Target CPU utilization (percent). With neither target set, Kubernetes scales on 80% average CPU utilization. |
| command | list | `[]` | Command of the web container (empty: the image entrypoint), e.g. `["php", "artisan", "octane:frankenphp", "--port=8000"]`. |
| commonLabels | object | `{}` | Labels added to every resource. |
| emptyDirSizeLimit | string | `"1Gi"` | Size limit of the emptyDir volumes (`/tmp`, writable paths, public files copy, Caddy state). Empty: no limit. |
| extraVolumeMounts | list | `[]` | Extra volume mounts of every Laravel container. |
| extraVolumes | list | `[]` | Extra volumes of every Laravel pod. |
| fullnameOverride | string | `""` | Override the full resource names. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Create a Gateway API HTTPRoute. |
| httpRoute.hostnames | list | `["chart-example.local"]` | Hostnames matched by the route. |
| httpRoute.parentRefs | list | `[{"name":"gateway","sectionName":"http"}]` | Gateways the route attaches to. |
| httpRoute.rules | list | `[{"matches":[{"path":{"type":"PathPrefix","value":"/"}}]}]` | Routing rules (each one is sent to the Service). |
| image.digest | string | `""` | Image digest (`sha256:...`). When set, it takes precedence over the tag. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `""` | Application image repository, fully qualified (e.g. `registry.example.com/acme/shop`). Required. |
| image.tag | string | `""` | Application image tag. Required unless `digest` is set (the chart appVersion is the Laravel version, not a tag of your image). |
| imagePullSecrets | list | `[]` | Secrets for pulling images from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Create an Ingress. |
| ingress.hosts | list | `[{"host":"chart-example.local","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts. |
| ingress.tls | list | `[]` | Ingress TLS. |
| initContainers | list | `[]` | Extra init containers of the web pods (run after the chart ones). |
| laravel.aws.access_key_id | string | `""` | AWS_ACCESS_KEY_ID, stored in the chart secret. |
| laravel.aws.bucket | string | `""` | AWS_BUCKET. |
| laravel.aws.enabled | bool | `false` | Render the AWS_* variables (S3 filesystem disk). |
| laravel.aws.endpoint | string | `""` | AWS_ENDPOINT (S3 compatible storage: MinIO, Garage, Ceph RGW...). |
| laravel.aws.existingSecret | string | `""` | Existing secret holding the AWS settings (each `secretKeys` entry overrides the plain value, `""` keeps it). |
| laravel.aws.region | string | `"us-east-1"` | AWS_DEFAULT_REGION. |
| laravel.aws.secretKeys.access_key_id | string | `"aws-access-key-id"` | Key of AWS_ACCESS_KEY_ID in `existingSecret`. |
| laravel.aws.secretKeys.bucket | string | `"aws-bucket"` | Key of AWS_BUCKET in `existingSecret`. |
| laravel.aws.secretKeys.region | string | `"aws-region"` | Key of AWS_DEFAULT_REGION in `existingSecret`. |
| laravel.aws.secretKeys.secret_access_key | string | `"aws-secret-access-key"` | Key of AWS_SECRET_ACCESS_KEY in `existingSecret`. |
| laravel.aws.secretKeys.use_path_style_endpoint | string | `"aws-use-path-style-endpoint"` | Key of AWS_USE_PATH_STYLE_ENDPOINT in `existingSecret`. |
| laravel.aws.secret_access_key | string | `""` | AWS_SECRET_ACCESS_KEY, stored in the chart secret. |
| laravel.aws.url | string | `""` | AWS_URL (public URL of the bucket). |
| laravel.aws.use_path_style_endpoint | bool | `false` | AWS_USE_PATH_STYLE_ENDPOINT. |
| laravel.bcrypt_rounds | int | `12` | BCRYPT_ROUNDS. |
| laravel.broadcast_connection | string | `"log"` | BROADCAST_CONNECTION. |
| laravel.cache.prefix | string | `""` | CACHE_PREFIX. |
| laravel.cache.store | string | `"database"` | CACHE_STORE. |
| laravel.cli_server_workers | int | `4` | PHP_CLI_SERVER_WORKERS (only used by `php artisan serve`). |
| laravel.database.connection | string | `"sqlite"` | DB_CONNECTION: `sqlite` (single web replica, file on the persistent volume), `pgsql`, `mysql`, `mariadb`, `sqlsrv`. |
| laravel.database.database | string | `""` | DB_DATABASE: database name, or the SQLite file path relative to `appPath` or absolute (empty: `storage/database/database.sqlite`). The SQLite file needs its own directory: it is mounted from the persistent volume. |
| laravel.database.enabled | bool | `true` | Render the DB_* variables. |
| laravel.database.existingSecret | string | `""` | Existing secret holding the connection settings. Each `secretKeys` entry read from it overrides the plain value; set an entry to `""` to keep the plain value (e.g. a secret holding only the password). |
| laravel.database.host | string | `""` | DB_HOST (required unless SQLite). |
| laravel.database.password | string | `""` | DB_PASSWORD, stored in the chart secret (required unless SQLite or `existingSecret`). |
| laravel.database.port | string | `""` | DB_PORT (empty: the default port of the connection). |
| laravel.database.secretKeys.database | string | `"database-name"` | Key of DB_DATABASE in `existingSecret`. |
| laravel.database.secretKeys.host | string | `"database-host"` | Key of DB_HOST in `existingSecret`. |
| laravel.database.secretKeys.password | string | `"database-password"` | Key of DB_PASSWORD in `existingSecret`. |
| laravel.database.secretKeys.port | string | `"database-port"` | Key of DB_PORT in `existingSecret`. |
| laravel.database.secretKeys.username | string | `"database-username"` | Key of DB_USERNAME in `existingSecret`. |
| laravel.database.username | string | `""` | DB_USERNAME. |
| laravel.debug | bool | `false` | APP_DEBUG. Never enable it in production. |
| laravel.env | string | `"production"` | APP_ENV. |
| laravel.extraEnv | list | `[]` | Extra environment variables of every Laravel container (rendered last: they override the chart variables). |
| laravel.extraEnvFrom | list | `[]` | Extra envFrom sources of every Laravel container. |
| laravel.filesystem_disk | string | `"local"` | FILESYSTEM_DISK. Use `s3` (see `aws`) to scale out without a ReadWriteMany volume. |
| laravel.key.existingSecret | string | `""` | Existing secret holding APP_KEY (takes precedence over `value`). |
| laravel.key.existingSecretKey | string | `"key"` | Key of APP_KEY in `existingSecret`. |
| laravel.key.value | string | `""` | APP_KEY (`base64:...`). Leave empty to generate one, kept across upgrades. Set it explicitly, or use `existingSecret`, with GitOps tools that render templates offline. |
| laravel.locale.default | string | `"en"` | APP_LOCALE. |
| laravel.locale.faker | string | `"en_US"` | APP_FAKER_LOCALE. |
| laravel.locale.fallback | string | `"en"` | APP_FALLBACK_LOCALE. |
| laravel.log.channel | string | `"stderr"` | LOG_CHANNEL. `stderr` sends the logs to `kubectl logs`; file channels write to the ephemeral `storage/logs`. |
| laravel.log.deprecations_channel | string | `""` | LOG_DEPRECATIONS_CHANNEL. |
| laravel.log.level | string | `"info"` | LOG_LEVEL. |
| laravel.log.stack | string | `"single"` | LOG_STACK (channels of the `stack` channel). |
| laravel.mail.enabled | bool | `false` | Render the MAIL_* variables. |
| laravel.mail.existingSecret | string | `""` | Existing secret holding the mail settings (each `secretKeys` entry overrides the plain value, `""` keeps it). |
| laravel.mail.from.address | string | `"hello@example.com"` | MAIL_FROM_ADDRESS. |
| laravel.mail.from.name | string | `"$(APP_NAME)"` | MAIL_FROM_NAME. `$(APP_NAME)` is expanded by Kubernetes. |
| laravel.mail.host | string | `"127.0.0.1"` | MAIL_HOST. |
| laravel.mail.mailer | string | `"log"` | MAIL_MAILER. |
| laravel.mail.password | string | `""` | MAIL_PASSWORD, stored in the chart secret. |
| laravel.mail.port | int | `25` | MAIL_PORT. |
| laravel.mail.scheme | string | `""` | MAIL_SCHEME (`smtp` or `smtps`). |
| laravel.mail.secretKeys.host | string | `"mail-host"` | Key of MAIL_HOST in `existingSecret`. |
| laravel.mail.secretKeys.password | string | `"mail-password"` | Key of MAIL_PASSWORD in `existingSecret`. |
| laravel.mail.secretKeys.port | string | `"mail-port"` | Key of MAIL_PORT in `existingSecret`. |
| laravel.mail.secretKeys.username | string | `"mail-username"` | Key of MAIL_USERNAME in `existingSecret`. |
| laravel.mail.username | string | `""` | MAIL_USERNAME. |
| laravel.maintenance.driver | string | `"file"` | APP_MAINTENANCE_DRIVER. Use `cache` with a shared store (database, redis) so `php artisan down` reaches every pod. |
| laravel.maintenance.store | string | `""` | APP_MAINTENANCE_STORE (cache store of the `cache` driver). |
| laravel.memcached.host | string | `""` | MEMCACHED_HOST. |
| laravel.name | string | `"Laravel"` | APP_NAME. |
| laravel.queue_connection | string | `"database"` | QUEUE_CONNECTION. |
| laravel.redis.client | string | `"phpredis"` | REDIS_CLIENT. |
| laravel.redis.enabled | bool | `false` | Render the REDIS_* variables. |
| laravel.redis.existingSecret | string | `""` | Existing secret holding the Redis settings (each `secretKeys` entry overrides the plain value, `""` keeps it). |
| laravel.redis.host | string | `"127.0.0.1"` | REDIS_HOST. |
| laravel.redis.password | string | `""` | REDIS_PASSWORD, stored in the chart secret. |
| laravel.redis.port | int | `6379` | REDIS_PORT. |
| laravel.redis.secretKeys.host | string | `"redis-host"` | Key of REDIS_HOST in `existingSecret`. |
| laravel.redis.secretKeys.password | string | `"redis-password"` | Key of REDIS_PASSWORD in `existingSecret`. |
| laravel.redis.secretKeys.port | string | `"redis-port"` | Key of REDIS_PORT in `existingSecret`. |
| laravel.secretEnv | object | `{}` | Secret environment variables (`NAME: value`), stored in the chart secret and injected with secretKeyRef. |
| laravel.session.domain | string | `""` | SESSION_DOMAIN. |
| laravel.session.driver | string | `"database"` | SESSION_DRIVER. Use a shared store (database, redis) with several web replicas. |
| laravel.session.encrypt | bool | `false` | SESSION_ENCRYPT. |
| laravel.session.lifetime | int | `120` | SESSION_LIFETIME (minutes). |
| laravel.session.path | string | `"/"` | SESSION_PATH. |
| laravel.url | string | `""` | APP_URL (empty: derived from the first Ingress host, else Laravel's default). |
| laravel.vite.app_name | string | `"$(APP_NAME)"` | VITE_APP_NAME. |
| laravel.vite.enabled | bool | `false` | Render VITE_APP_NAME (only useful to server-side code: Vite variables are compiled at build time). |
| lifecycle | object | `{"preStop":{"exec":{"command":["sh","-c","sleep 5"]}}}` | Lifecycle hooks of the web container (the sleep lets endpoints drain before the server stops). |
| livenessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/up","port":"http"},"periodSeconds":10,"timeoutSeconds":5}` | Liveness probe of the HTTP container (FrankenPHP, or nginx with `fpm`). `/up` is the health route of Laravel 11+. |
| nameOverride | string | `""` | Override the chart name. |
| networkPolicy.allowedFrom | list | `[]` | Peers allowed to reach the web pods (e.g. the ingress controller namespace). Empty: any source. Pods of the release are always allowed. |
| networkPolicy.egress.enabled | bool | `false` | Restrict egress of every pod to DNS, the release pods and `rules`. |
| networkPolicy.egress.rules | list | `[]` | Allowed egress rules (database, Redis, SMTP, S3, external APIs...). |
| networkPolicy.enabled | bool | `false` | Create NetworkPolicies: the web pods only accept HTTP, the other pods accept nothing. |
| nodeSelector | object | `{}` | Node selector. |
| persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes. With `ReadWriteOnce` the web Deployment runs a single replica (`Recreate`) and the queue/scheduler pods are scheduled on its node; `ReadWriteMany` lifts both limits. |
| persistence.annotations | object | `{}` | PVC annotations. |
| persistence.enabled | bool | `true` | Store `paths` (and the SQLite database) on a PersistentVolumeClaim shared by the web, queue and scheduler pods. |
| persistence.existingClaim | string | `""` | Use an existing PVC. |
| persistence.paths | list | `["storage/app"]` | Directories stored on the volume, relative to `appPath` or absolute (each one in its own sub-directory of the volume). |
| persistence.size | string | `"5Gi"` | Volume size. |
| persistence.storageClass | string | `""` | Storage class (empty uses the cluster default). |
| podAnnotations | object | `{}` | Pod annotations (every pod). |
| podDisruptionBudget.enabled | bool | `false` | Create a PodDisruptionBudget for the web pods (useful with 2+ replicas). |
| podDisruptionBudget.maxUnavailable | string | `nil` | Maximum unavailable pods (used instead of minAvailable when set). |
| podDisruptionBudget.minAvailable | int | `1` | Minimum available pods. |
| podLabels | object | `{}` | Pod labels (every pod). |
| podSecurityContext | object | `{"fsGroup":33,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":33,"runAsNonRoot":true,"runAsUser":33,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. 33 is `www-data` in the Debian based PHP images (82 in the Alpine ones): files only need to be readable by this user, writable paths are volumes. |
| prepareResources | object | `{"limits":{"memory":"128Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | Resources of the `prepare` init container (seeds the writable paths, copies the public files for nginx). |
| priorityClassName | string | `""` | Priority class of the pods. |
| publicPath | string | `""` | Public directory served over HTTP, relative to `appPath` or absolute (empty: `<appPath>/public`). With the nginx sidecar it is copied from the image and served at the same path. |
| readinessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/up","port":"http"},"periodSeconds":5,"timeoutSeconds":5}` | Readiness probe of the HTTP container. |
| replicaCount | int | `1` | Number of web replicas. Must stay at 1 with SQLite or a ReadWriteOnce persistent volume. |
| resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"256Mi"}}` | Resources of the web container (FrankenPHP or PHP-FPM). |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Security context of the Laravel containers. |
| seedWritablePaths | bool | `true` | Copy what the image ships in each writable path before Laravel starts (keeps the `bootstrap/cache/*.php` files and the directory skeleton built into the image). Needs `/bin/sh` and `cp` in the image. |
| service.annotations | object | `{}` | Service annotations. |
| service.port | int | `80` | Service port (mapped to the HTTP port of the web pods). |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | Service account annotations (cloud workload identity...). |
| serviceAccount.automount | bool | `false` | Mount the service account token. Laravel does not talk to the Kubernetes API. |
| serviceAccount.create | bool | `true` | Create a dedicated service account. |
| serviceAccount.name | string | `""` | Service account name (generated when empty). |
| sidecars | list | `[]` | Extra containers of the web pods. |
| startupProbe | object | `{"failureThreshold":30,"httpGet":{"path":"/up","port":"http"},"periodSeconds":5,"timeoutSeconds":5}` | Startup probe of the HTTP container. |
| terminationGracePeriodSeconds | int | `30` | Grace period of the web pods. |
| tests.image | string | `""` | Image used by `helm test` (needs `wget`; defaults to the nginx image). |
| tests.path | string | `"/up"` | Path requested by `helm test`. |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints of the web pods. |
| updateStrategy | object | `{}` | Web Deployment update strategy. The chart forces `Recreate` with a ReadWriteOnce persistent volume. |
| workload.migrations.activeDeadlineSeconds | int | `600` |  |
| workload.migrations.affinity | object | `{}` | Affinity (empty: the top-level `affinity`). |
| workload.migrations.backoffLimit | int | `1` | Retries of the migration Job. |
| workload.migrations.command | list | `["php","artisan","migrate","--force"]` | Migration command. |
| workload.migrations.enabled | bool | `true` | Run the database migrations: a pre-install/pre-upgrade Job, or with SQLite an init container of the web pod. |
| workload.migrations.nodeSelector | object | `{}` | Node selector (empty: the top-level `nodeSelector`). |
| workload.migrations.resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"50m","memory":"128Mi"}}` | Resources of the migrations. |
| workload.migrations.tolerations | list | `[]` | Tolerations (empty: the top-level `tolerations`). |
| workload.nginx.clientMaxBodySize | string | `"16m"` | Maximum request body size (uploads). |
| workload.nginx.config | string | `""` | Replace the default `server { }` block (it must listen on `port`, use `root` = the public path and pass PHP to `127.0.0.1:<fpm port>`). |
| workload.nginx.extraVolumeMounts | list | `[]` | Extra volume mounts of the nginx container. |
| workload.nginx.image.digest | string | `""` | Image digest (takes precedence over the tag). |
| workload.nginx.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| workload.nginx.image.repository | string | `"docker.io/nginxinc/nginx-unprivileged"` | nginx image repository (must run unprivileged). |
| workload.nginx.image.tag | string | `"1.30.6-alpine-slim"` | nginx image tag. |
| workload.nginx.ipv6 | bool | `false` | Also listen on IPv6 (dual-stack clusters). nginx fails to start in pods without IPv6. |
| workload.nginx.lifecycle | object | `{"preStop":{"exec":{"command":["sh","-c","sleep 5"]}}}` | Lifecycle hooks of the nginx container (the sleep lets endpoints drain before nginx stops). |
| workload.nginx.port | int | `8080` | Port nginx listens on. |
| workload.nginx.resources | object | `{"limits":{"memory":"128Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | Resources of the nginx container. |
| workload.nginx.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true,"runAsGroup":101,"runAsNonRoot":true,"runAsUser":101}` | Security context of the nginx container. |
| workload.nginx.workerProcesses | int | `2` | nginx worker processes (`auto` starts one per node CPU). |
| workload.queueWorker.affinity | object | `{}` | Affinity (empty: the top-level `affinity`). |
| workload.queueWorker.command | list | `["php","artisan","queue:work","--sleep=3","--tries=3"]` | Queue worker command. |
| workload.queueWorker.enabled | bool | `true` | Run queue workers (`php artisan queue:work`). |
| workload.queueWorker.livenessProbe | object | `{}` | Liveness probe of the queue workers. |
| workload.queueWorker.nodeSelector | object | `{}` | Node selector (empty: the top-level `nodeSelector`). |
| workload.queueWorker.replicaCount | int | `1` | Number of queue worker pods. |
| workload.queueWorker.resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"50m","memory":"128Mi"}}` | Resources of the queue workers. |
| workload.queueWorker.terminationGracePeriodSeconds | int | `60` | Seconds a worker gets to finish its current job on shutdown (keep it above the job timeout). |
| workload.queueWorker.tolerations | list | `[]` | Tolerations (empty: the top-level `tolerations`). |
| workload.runtime.fpm.livenessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"tcpSocket":{"port":"fastcgi"},"timeoutSeconds":3}` | Liveness probe of the PHP-FPM container (the HTTP probes run on the nginx sidecar). |
| workload.runtime.fpm.port | int | `9000` | Port PHP-FPM listens on (FastCGI). The nginx sidecar reaches it on 127.0.0.1. |
| workload.runtime.fpm.readinessProbe | object | `{"failureThreshold":3,"periodSeconds":5,"tcpSocket":{"port":"fastcgi"},"timeoutSeconds":3}` | Readiness probe of the PHP-FPM container. |
| workload.runtime.frankenphp.keepNetBindService | bool | `true` | Keep NET_BIND_SERVICE in the bounding set: the official FrankenPHP binary carries it as a file capability and cannot be executed without it. Set false if your image strips it (`setcap -r /usr/local/bin/frankenphp`). |
| workload.runtime.frankenphp.port | int | `8000` | Port FrankenPHP listens on (unprivileged). |
| workload.runtime.frankenphp.serverName | string | `""` | SERVER_NAME given to the stock FrankenPHP Caddyfile (empty: `:<port>`, plain HTTP on that port). |
| workload.runtime.type | string | `"frankenphp"` | How the web pods serve HTTP: `frankenphp` (the image serves HTTP itself) or `fpm` (PHP-FPM + nginx sidecar). |
| workload.scheduler.affinity | object | `{}` | Affinity (empty: the top-level `affinity`). |
| workload.scheduler.backoffLimit | int | `0` | Retries of a failed run (a retry would run in a later minute). |
| workload.scheduler.command | list | `["php","artisan","schedule:run"]` | Command of the CronJob. |
| workload.scheduler.concurrencyPolicy | string | `"Forbid"` | CronJob concurrency policy. `Forbid` skips a minute while the previous run is still going (use `runInBackground()` for long tasks). |
| workload.scheduler.enabled | bool | `true` | Run the Laravel scheduler. |
| workload.scheduler.failedJobsHistoryLimit | int | `1` | Failed Jobs kept. |
| workload.scheduler.mode | string | `"cronjob"` | `cronjob`: a CronJob runs `schedule:run` every minute. `deployment`: one long-running pod runs `schedule:work` (no pod per minute). |
| workload.scheduler.nodeSelector | object | `{}` | Node selector (empty: the top-level `nodeSelector`). |
| workload.scheduler.resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"50m","memory":"128Mi"}}` | Resources of the scheduler. |
| workload.scheduler.schedule | string | `"* * * * *"` | Cron schedule of the CronJob. |
| workload.scheduler.startingDeadlineSeconds | int | `60` | Seconds after its schedule a missed run may still start. |
| workload.scheduler.successfulJobsHistoryLimit | int | `1` | Successful Jobs kept. |
| workload.scheduler.tolerations | list | `[]` | Tolerations (empty: the top-level `tolerations`). |
| workload.scheduler.ttlSecondsAfterFinished | int | `120` | Seconds a finished Job is kept. |
| workload.scheduler.workCommand | list | `["php","artisan","schedule:work"]` | Command of the `deployment` mode. |
| writablePaths | list | `["storage/framework","storage/logs","storage/app","bootstrap/cache"]` | Directories Laravel writes to, relative to `appPath` or absolute. They are emptyDir volumes so the root filesystem can stay read-only; a path also listed in `persistence.paths` lives on the persistent volume instead. |

## License

The chart is released under the MIT license. Laravel is licensed under the MIT license; your application image keeps
its own license.
