# Cloudreve Helm Chart

![Version: 2026.10.1](https://img.shields.io/badge/Version-2026.10.1-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 4.19.1](https://img.shields.io/badge/AppVersion-4.19.1-informational?style=flat-square)

A Helm chart for [Cloudreve v4](https://cloudreve.org/), a self-hosted file management and sharing system with
support for multiple storage providers (local, S3, OneDrive, OSS, COS, ...).

## Features

- **Cloudreve v4** with SQLite (default, in the data volume), PostgreSQL, MySQL or MariaDB
- Optional **Redis** for sessions and caches (recommended in production)
- **Secrets stay secret**: the session secret is generated and kept across upgrades (or read from your Secret);
  `conf.ini` is rendered at startup into a memory-backed volume, never into a ConfigMap
- **Hardened**: non-root (uid 1000), read-only root filesystem, every capability dropped, seccomp `RuntimeDefault`,
  no service account token. The Cloudreve binary is started directly (the image entrypoint runs aria2 under supervisord as root)
- Persistent `/cloudreve/data` (enabled by default), Ingress or Gateway API HTTPRoute, probes on `/api/v4/site/ping`, `helm test`

## Installation

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
helm install my-storage unxwares/cloudreve --namespace storage --create-namespace
```

The first account registered becomes the administrator. Charts are signed: see
[verifying signatures](https://github.com/UnxWares/helm/blob/main/SECURITY.md#verifying-chart-signatures).

## Examples

### PostgreSQL + Redis behind an Ingress

```yaml
database:
  type: postgres
  host: cloudreve-db-rw.databases.svc
  port: 5432
  name: cloudreve
  user: cloudreve
  existingSecret: cloudreve-db      # key: password
redis:
  enabled: true
  server: valkey.cache.svc:6379
  existingSecret: cloudreve-redis   # key: password
ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    cert-manager.io/cluster-issuer: letsencrypt
  hosts:
    - host: cloud.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: cloud-example-com-tls
      hosts:
        - cloud.example.com
extraEnv:
  # Seeds the site URL at first install only.
  - name: CR_SETTING_DEFAULT_siteURL
    value: https://cloud.example.com
```

### PostgreSQL over TLS

Cloudreve ignores `sslmode` in the individual fields: use a connection URL.

```yaml
database:
  type: postgres
  existingSecret: cloudreve-db
  existingSecretKeys:
    password: password
    url: url    # postgres://cloudreve:...@db:5432/cloudreve?sslmode=verify-full
```

### Extra conf.ini settings

```yaml
cloudreve:
  config:
    CORS:
      AllowOrigins: "https://app.example.com"
      AllowCredentials: true
```

## Upgrading

### From 2026.2.x (Cloudreve 3.8) to 2026.10.1 (Cloudreve 4)

Cloudreve 4 is a new major version with a different database schema, and the previous chart could not render
its configuration (`confini.data`), so a fresh install is the expected path.

To migrate an existing Cloudreve 3.8 instance (see the [official guide](https://docs.cloudreve.org/en/maintain/upgrade-from-v3)):

1. Back up the v3 database and files.
2. Install this chart with a **new, empty database** (`database.*`) and scale it to 0 once it started:
   `kubectl scale deploy/<release>-cloudreve --replicas 0`.
3. Run the migration with the v3 `conf.ini` (its directory must be writable) against the v4 `conf.ini`:
   `cloudreve migrate --v3-conf /path/to/v3/conf.ini -c /etc/cloudreve/conf.ini`
   The Cloudreve docs recommend running the migration with a 4.0.x binary, as the tool will be removed later.
4. Local files uploaded with v3 are expected under `/cloudreve/uploads`: copy them into the new volume accordingly.
5. Scale back to 1.

Value changes: `confini.fromSecret` + `confini.secretName` → `confini.existingSecret` (old names still work);
`confini.data`, `replicaCount`, `autoscaling`, `persistence.type`, `persistence.inMemory` and `createConfigmap` are gone;
`database.type` now defaults to `sqlite` and the defaults `root`/`root` were removed.

## Requirements

Kubernetes: `>=1.27.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity rules. |
| annotations | object | `{}` | Deployment annotations. |
| cloudreve.config | object | `{}` | Extra conf.ini sections and keys, e.g. `{CORS: {AllowOrigins: "*"}}` (https://docs.cloudreve.org). |
| cloudreve.existingSecret | string | `""` | Existing secret holding the session secret. |
| cloudreve.existingSecretKey | string | `"session-secret"` | Key of the session secret in `existingSecret`. |
| cloudreve.logLevel | string | `"info"` | Log level (`debug`, `info`, `warning`, `error`). |
| cloudreve.proxyHeader | string | `"X-Forwarded-For"` | HTTP header carrying the client IP when Cloudreve runs behind a reverse proxy. |
| cloudreve.sessionSecret | string | `""` | Session secret (64+ random characters). Leave empty to generate one (kept across upgrades). |
| confini.existingSecret | string | `""` | Existing secret containing a full `conf.ini` key. |
| database.charset | string | `"utf8mb4"` | MySQL/MariaDB charset. |
| database.existingSecret | string | `""` | Existing secret holding the database password (and optionally the URL). |
| database.existingSecretKeys.password | string | `"password"` | Key of the password in `existingSecret`. |
| database.existingSecretKeys.url | string | `""` | Key of the connection URL in `existingSecret` (optional). |
| database.host | string | `""` | Database host. |
| database.name | string | `"cloudreve"` | Database name. |
| database.password | string | `""` | Database password (ignored when `existingSecret` is set). |
| database.port | int | `5432` | Database port. |
| database.type | string | `"sqlite"` | Database type: `sqlite` (stored in the data volume), `postgres`, `mysql` or `mariadb`. |
| database.url | string | `""` | Full connection URL (overrides host/port/user/password/name). Needed for PostgreSQL TLS, e.g. `postgres://user:pass@host:5432/db?sslmode=verify-full`. Stored in the chart secret. |
| database.user | string | `"cloudreve"` | Database user. |
| extraEnv | list | `[]` | Extra environment variables. Do not put secrets in `CR_CONF_*` variables: Cloudreve logs their values. |
| extraVolumeMounts | list | `[]` | Extra volume mounts of the Cloudreve container. |
| extraVolumes | list | `[]` | Extra volumes. |
| fullnameOverride | string | `""` | Override the full resource names. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Expose Cloudreve through a Gateway API HTTPRoute. |
| httpRoute.hostnames | list | `["chart-example.local"]` | Hostnames. |
| httpRoute.parentRefs | list | `[{"name":"gateway","sectionName":"http"}]` | Gateways this route is attached to. |
| httpRoute.rules | list | `[{"matches":[{"path":{"type":"PathPrefix","value":"/"}}]}]` | Rules (every rule is sent to the Cloudreve service). |
| image.digest | string | `""` | Image digest (`sha256:...`). When set, it takes precedence over the tag. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"docker.io/cloudreve/cloudreve"` | Cloudreve image repository. |
| image.tag | string | `""` | Image tag (defaults to the chart appVersion). |
| imagePullSecrets | list | `[]` | Secrets for pulling images from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations. Raise the body size limit of your controller for uploads (e.g. `nginx.ingress.kubernetes.io/proxy-body-size: "0"`). |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Expose Cloudreve through an Ingress. |
| ingress.hosts | list | `[{"host":"chart-example.local","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts. |
| ingress.tls | list | `[]` | Ingress TLS. |
| labels | object | `{}` | Deployment labels. |
| livenessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/api/v4/site/ping","port":"http"},"periodSeconds":20,"timeoutSeconds":5}` | Liveness probe. |
| nameOverride | string | `""` | Override the chart name. |
| namespaceOverride | string | `""` | Override the deployment namespace. |
| nodeSelector | object | `{}` | Node selector. |
| persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes. |
| persistence.annotations | object | `{}` | PVC annotations. |
| persistence.enabled | bool | `true` | Persist /cloudreve/data in a PVC. Without it, files and the SQLite database are lost when the pod restarts. |
| persistence.existingClaim | string | `""` | Use an existing PVC. |
| persistence.extraPvcLabels | object | `{}` | Extra PVC labels. |
| persistence.size | string | `"10Gi"` | Volume size. |
| persistence.storageClassName | string | `""` | Storage class (empty uses the cluster default). |
| persistence.subPath | string | `""` | Sub-directory of the volume to mount. |
| podAnnotations | object | `{}` | Pod annotations. |
| podLabels | object | `{}` | Pod labels. |
| podPortName | string | `"http"` | Name of the container port. |
| podSecurityContext | object | `{"fsGroup":1000,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":1000,"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Cloudreve runs fine as an arbitrary non-root user. |
| priorityClassName | string | `""` | Priority class of the pod. |
| readinessProbe | object | `{"httpGet":{"path":"/api/v4/site/ping","port":"http"},"periodSeconds":10,"timeoutSeconds":5}` | Readiness probe. |
| redis.db | int | `0` | Redis database index. |
| redis.enabled | bool | `false` | Use a Redis server. |
| redis.existingSecret | string | `""` | Existing secret holding the Redis password. |
| redis.existingSecretKey | string | `"password"` | Key of the password in `existingSecret`. |
| redis.password | string | `""` | Redis password (ignored when `existingSecret` is set). |
| redis.server | string | `""` | Redis address (`host:port`). |
| redis.tlsSkipVerify | bool | `false` | Skip TLS certificate verification (Cloudreve's own default is true; the chart verifies). |
| redis.useTLS | bool | `false` | Connect with TLS. |
| redis.user | string | `""` | Redis user (ACL), if any. |
| resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"128Mi"}}` | Resource requests and limits. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. |
| service.annotations | object | `{}` | Service annotations. |
| service.port | int | `80` | Service port. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | Service account annotations. |
| serviceAccount.automount | bool | `false` | Cloudreve never talks to the Kubernetes API: the token is not mounted. |
| serviceAccount.create | bool | `true` | Create a dedicated service account. |
| serviceAccount.name | string | `""` | Service account name (generated when empty). |
| startupProbe | object | `{"failureThreshold":60,"httpGet":{"path":"/api/v4/site/ping","port":"http"},"periodSeconds":5}` | Startup probe (the first start runs the database migrations). |
| timezone | string | `"UTC"` | Timezone of the container (the image defaults to Asia/Shanghai). |
| tolerations | list | `[]` | Tolerations. |

## Credits

See [CREDITS.md](CREDITS.md).

## License

The chart is released under the MIT license. Cloudreve is licensed under the GPL-3.0.
