# Laravel (generic) Helm Chart

![Version: 2026.10.2](https://img.shields.io/badge/Version-2026.10.2-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 12.x](https://img.shields.io/badge/AppVersion-12.x-informational?style=flat-square)

Run **your own [Laravel](https://laravel.com) application image** on Kubernetes, packaged by UnxWares:
web pods (FrankenPHP, or PHP-FPM with an nginx sidecar), queue workers, scheduler and database
migrations, with hardened defaults. The chart ships no application: you build the image, the chart runs it.

## Features

- **Two runtimes**: `frankenphp` (the image serves HTTP itself, Octane compatible) or `fpm` (PHP-FPM + an unprivileged nginx sidecar sharing the public files of your image).
- **Queue workers** (`queue:work`), **scheduler** (CronJob running `schedule:run` every minute, or a `schedule:work` Deployment) and **migrations** run before every install/upgrade.
- **Secrets never in plain environment values**: APP_KEY, database/Redis/mail passwords, AWS keys and `laravel.secretEnv` live in a Secret (or your own existing Secrets) and are injected with `secretKeyRef`. APP_KEY is generated and kept across upgrades when you do not provide one.
- **Hardened by default**: non-root (uid 33), read-only root filesystem, every capability dropped, seccomp `RuntimeDefault`, no service account token. The directories Laravel writes to are volumes, seeded with what your image ships there.
- **Persistence** for `storage/app` and SQLite (PVC kept on uninstall), with the scheduling constraints a ReadWriteOnce volume needs.
- Ingress or Gateway API HTTPRoute, HPA, PodDisruptionBudget, NetworkPolicies (ingress + optional egress lockdown), `helm test`.

## Requirements for your image

| | FrankenPHP | PHP-FPM |
|---|---|---|
| Base image | [`dunglas/frankenphp`](https://frankenphp.dev/docs/docker/) (or Octane with FrankenPHP) | [`php:*-fpm`](https://hub.docker.com/_/php) |
| `appPath` (application directory) | `/app` (default) | usually `/var/www/html` |
| Listens on | `workload.runtime.frankenphp.port` (8000) | `workload.runtime.fpm.port` (9000, FastCGI) |

- The image must contain `/bin/sh` and `cp` (true for every official PHP image): an init container copies the content of the writable paths and of `public/` into volumes.
- Files must be readable by uid 33 (`www-data` in the Debian images; files are world-readable by default). Change `podSecurityContext` for another user.
- The root filesystem is read-only: everything is decided at build time (`composer install --no-dev`, `npm run build`, `php artisan storage:link`...). Run `php artisan optimize` at container start rather than at build time, since configuration comes from environment variables.
- Laravel 11+ exposes `/up`, used by the probes. Older applications: add a health route or change the probes.
- **FrankenPHP and capabilities**: the official binary carries the `cap_net_bind_service` file capability and cannot even start when the capability is missing from the bounding set. The chart keeps `NET_BIND_SERVICE` on the web container (the only capability allowed by the Pod Security Standards *restricted* profile). If your Dockerfile runs `setcap -r /usr/local/bin/frankenphp` (recommended), set `workload.runtime.frankenphp.keepNetBindService=false`.

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

Charts are signed: see [verifying signatures](https://github.com/UnxWares/helm/blob/main/SECURITY.md#verifying-chart-signatures)
and add `--verify --keyring <keyring>` to `helm install`.

## Examples

### FrankenPHP with SQLite (defaults)

A single web replica with the SQLite database and `storage/app` on a PVC; migrations run in an init container of the web pod.

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

## How it works

- **Web pods** run the `app` container (FrankenPHP or PHP-FPM). With `fpm`, an `nginx` sidecar listens on 8080, serves the static files and passes PHP to `127.0.0.1:9000`. The `public/` directory is copied from your image into a volume mounted at the same path in nginx, so `SCRIPT_FILENAME` is valid in both containers; files of the `public` disk (`storage/app/public`) are served from the persistent volume when it holds them. The Service maps `service.port` to the HTTP port of the pod.
- **Writable paths** (`writablePaths`) are emptyDir volumes. The `prepare` init container seeds them with what the image contains (`bootstrap/cache/packages.php`, the `storage` skeleton...) and creates the directories Laravel expects. Paths listed in `persistence.paths` (or inside them) are stored on the PVC instead. `storage/app` is ephemeral unless persisted: use `persistence` or S3 for uploads.
- **Migrations** (`workload.migrations`) run in a `pre-install,pre-upgrade` hook Job, before the new pods roll out. Release resources do not exist yet at that point, so the Job uses its own copy of the Secret (deleted once it succeeds), no PVC, and the namespace default service account (or `serviceAccount.name` when `serviceAccount.create=false`). With SQLite, the single web pod creates the database file and migrates in an init container instead. Raise `helm --timeout` for long migrations.
- **Queue workers** get `terminationGracePeriodSeconds: 60` to finish their current job. **Scheduler**: a CronJob with `concurrencyPolicy: Forbid` and no retry (a retry would run the tasks of a past minute), or `mode: deployment` for a single `schedule:work` pod.
- **ReadWriteOnce volume**: the web Deployment keeps one replica with the `Recreate` strategy and the queue/scheduler pods are scheduled on the node of the web pod (required pod affinity). A ReadWriteMany volume, or `persistence.enabled=false` with S3, lifts both limits.
- **Graceful shutdown**: a 5 s `preStop` sleep on the web containers lets endpoints drain before FrankenPHP/PHP-FPM/nginx stop.
- **Logs** go to stderr by default (`laravel.log.channel`), visible with `kubectl logs`.

## Upgrading

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

## Notes

- **APP_KEY**: when it is generated, the Secret holding it is kept on `helm uninstall` (like the PVC) so a reinstall of the same release reuses it. Delete the Secret and the PVC to start from scratch.
- **GitOps**: when APP_KEY is generated, tools that render templates offline (Argo CD...) cannot read it back and would rotate it on every sync. Set `laravel.key.value` or `laravel.key.existingSecret`. Losing APP_KEY makes encrypted data and sessions unreadable.
- `helm lint` succeeds without values, but `helm template`/`helm install` fail until `image.repository` and `image.tag` are set.
- With several web replicas, use shared stores for sessions, cache and maintenance mode (database or Redis) and S3 (or a ReadWriteMany volume) for files.
- `php artisan down` with the default `file` maintenance driver only affects one pod: use `laravel.maintenance.driver=cache` with a shared store.

## Requirements

Kubernetes: `>=1.27.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity rules. |
| appPath | string | `"/app"` | Directory of the Laravel application in the image (its WORKDIR): `/app` for FrankenPHP images, usually `/var/www/html` for the official PHP-FPM images. |
| args | list | `[]` | Arguments of the web container. |
| autoscaling.enabled | bool | `false` | Enable the web HorizontalPodAutoscaler (not with SQLite or a ReadWriteOnce volume). |
| autoscaling.maxReplicas | int | `10` | Maximum replicas. |
| autoscaling.minReplicas | int | `2` | Minimum replicas. |
| autoscaling.targetCPUUtilizationPercentage | int | `80` | Target CPU utilization. |
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

The chart is released under the MIT license. Laravel is licensed under the MIT license; your application image keeps its own license.
