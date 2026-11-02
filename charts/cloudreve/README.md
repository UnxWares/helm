# Cloudreve Helm Chart

![Version: 2026.11.1](https://img.shields.io/badge/Version-2026.11.1-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 4.19.1](https://img.shields.io/badge/AppVersion-4.19.1-informational?style=flat-square)

[Cloudreve](https://cloudreve.org/) is a self-hosted file management and sharing system: personal and shared files,
public links, WebDAV, previews and thumbnails, with storage on the local disk or on remote providers (S3, OneDrive,
OSS, COS...). This chart, maintained by UnxWares, runs Cloudreve v4 as a single pod with its data on a persistent
volume, and a database of your choice.

## Features

- **Cloudreve v4** on SQLite (default, in the data volume), PostgreSQL, MySQL or MariaDB.
- Optional **Redis** for sessions and caches, so they survive restarts.
- **Secrets stay in Secrets**: the session secret is generated once and kept across upgrades (or read from your own
  Secret); database and Redis passwords come from Secrets; `conf.ini` is rendered at startup into a memory-backed
  volume, never stored in a ConfigMap or on the node disk.
- **Hardened pod**: non-root (uid 1000), read-only root filesystem, every capability dropped, seccomp
  `RuntimeDefault`, no service account token.
- **UnxWares image by default**: Cloudreve built from its release sources with current Go modules on a current
  Alpine (see [Images](#images)); the official image stays one value away.
- Persistent `/cloudreve/data`, Ingress or Gateway API HTTPRoute, startup, liveness and readiness probes, `helm test`,
  and an end-to-end test in CI.

## Architecture

| Resource | Name | Purpose |
|---|---|---|
| Deployment (1 replica, `Recreate`) | `<release>-cloudreve` | Cloudreve on port 5212. Cloudreve keeps WebDAV locks, its task queue and cron jobs in memory, so it runs a single replica. |
| Init container `render-config` | in the Deployment | Fills `conf.ini` from the template and the secret-backed environment, into a memory-backed volume. Skipped with `confini.existingSecret`. |
| Service | `<release>-cloudreve` | Port `service.port` (80) to the container port 5212. |
| PersistentVolumeClaim | `<release>-cloudreve` | `/cloudreve/data`: SQLite database, files of the local storage policy, avatars, caches. Kept on uninstall. |
| Secret | `<release>-cloudreve` | Session secret, database password or URL, Redis password (each only when not read from your own Secret). |
| ConfigMap | `<release>-cloudreve` | `conf.ini` template with `@@...@@` placeholders, and the `awk` script that fills them. No secret in it. |
| ServiceAccount | `<release>-cloudreve` | Dedicated account, token not mounted (`serviceAccount.automount: false`). |
| Ingress or HTTPRoute | `<release>-cloudreve` | Optional: `ingress.enabled` or `httpRoute.enabled`. |

Volumes of the pod: `/etc/cloudreve` (rendered `conf.ini`, memory-backed, 1 Mi), `/cloudreve/data` (the PVC, or an
`emptyDir` without persistence) and `/tmp` (`emptyDir`, 2 Gi, upload chunks and thumbnail work).

## Images

| `imageProvider` | Image | Notes |
|---|---|---|
| `unxwares` (default) | `ghcr.io/unxwares/cloudreve:<appVersion>` | Built from the Cloudreve release sources (web UI included) with the Go module updates proposed upstream in [cloudreve/cloudreve#3618](https://github.com/cloudreve/cloudreve/issues/3618), on a current Alpine. Same thumbnail and media tools as upstream (libvips, FFmpeg, LibreOffice, libheif, libraw), no aria2 or supervisord. Rebuilt twice a week, signed with cosign. |
| `upstream` | `docker.io/cloudreve/cloudreve:<appVersion>` | The official image. The chart starts the binary directly, so its root entrypoint (aria2 under supervisord) never runs. |

Sources, build details and the cosign verification command are in
[images/](https://github.com/UnxWares/helm/tree/main/images). The known vulnerabilities of both images are tracked
daily in the [CVE watch](https://github.com/UnxWares/helm/issues?q=is%3Aissue+is%3Aopen+label%3Acve-watch) issue.

Set `image.repository` and `image.tag` to use your own build, and `image.digest` to pin an image by digest:

```yaml
image:
  digest: sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

## Requirements

- Kubernetes `>=1.27.0-0`.
- A storage class for the data volume (or `persistence.existingClaim`). With the SQLite database and the local
  storage policy, everything lives on this volume: size it for your files.
- For PostgreSQL, MySQL or MariaDB: an existing server and an empty database with its user.
- To expose it: an Ingress controller, or a Gateway API implementation for the HTTPRoute.
- Nodes on amd64 or arm64.

## Installation

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
helm install my-storage unxwares/cloudreve --namespace storage --create-namespace
```

Packages are signed with the UnxWares Helm Charts key (`7902 E52E A435 EF27 C643  2E53 78D6 B532 C599 DA9B`). To check
the signature at install time:

```bash
curl -fsSL https://helm.unxwares.studio/pgp-public-key.asc | gpg --import
gpg --export 7902E52EA435EF27C6432E5378D6B532C599DA9B > ~/.gnupg/unxwares-helm.gpg
helm install my-storage unxwares/cloudreve --namespace storage --create-namespace \
  --verify --keyring ~/.gnupg/unxwares-helm.gpg
```

Then open it and **register the first account right away: it becomes the administrator**.

```bash
kubectl --namespace storage port-forward svc/my-storage-cloudreve 8080:80
# http://127.0.0.1:8080
```

## Configuration

### Persistence

`/cloudreve/data` is a PVC of `persistence.size` (10 Gi) by default. Without persistence (`persistence.enabled:
false`) the SQLite database and every uploaded file are lost when the pod restarts. To reuse a volume you manage:

```yaml
persistence:
  existingClaim: cloudreve-data
```

`persistence.storageClassName`, `accessModes`, `annotations`, `extraPvcLabels` and `subPath` (rendered with `tpl`)
configure the claim.

### Database

SQLite is the default and needs nothing else. For a server, set `database.type` to `postgres`, `mysql` or `mariadb`,
the connection settings, and the password, ideally from your own Secret:

```yaml
database:
  type: postgres
  host: cloudreve-db-rw.databases.svc
  port: 5432
  name: cloudreve
  user: cloudreve
  existingSecret: cloudreve-db        # key "password", see database.existingSecretKeys.password
```

MySQL and MariaDB also take `database.charset` (`utf8mb4`). Cloudreve ignores TLS settings in the separate fields: for
PostgreSQL over TLS, give a full connection URL, either in `database.url` (stored in the chart Secret) or in your
Secret (`database.existingSecretKeys.url`):

```yaml
database:
  type: postgres
  existingSecret: cloudreve-db
  existingSecretKeys:
    password: password
    url: url    # postgres://cloudreve:...@db:5432/cloudreve?sslmode=verify-full
```

The chart refuses to render a server database without a host (or URL) and a password (or Secret).

### Redis

```yaml
redis:
  enabled: true
  server: valkey.cache.svc:6379
  existingSecret: cloudreve-redis     # key "password", see redis.existingSecretKey
  db: 0
  useTLS: false
```

`redis.user` sets an ACL user. With `useTLS`, the chart verifies the server certificate (`redis.tlsSkipVerify:
false`), unlike Cloudreve's own default.

### Session secret

The session secret signs sessions. Left empty, the chart generates 64 random characters at install and reads them
back from the release Secret at every upgrade. Tools that render charts offline, such as Argo CD, cannot read it
back and would change it at every sync: give it yourself in that case.

```yaml
cloudreve:
  existingSecret: cloudreve-session   # key "session-secret", see cloudreve.existingSecretKey
```

### Exposure

Ingress (raise the body size limit of your controller for uploads):

```yaml
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
```

Gateway API:

```yaml
httpRoute:
  enabled: true
  parentRefs:
    - name: public-gateway
      namespace: gateways
      sectionName: https
  hostnames:
    - cloud.example.com
```

Behind a reverse proxy, Cloudreve takes the client address from `cloudreve.proxyHeader` (`X-Forwarded-For`). Set
the site URL once, at first install, so that the links Cloudreve generates use it:

```yaml
extraEnv:
  - name: CR_SETTING_DEFAULT_siteURL
    value: https://cloud.example.com
```

### Cloudreve settings

`cloudreve.logLevel` sets the log level. `cloudreve.config` adds sections and keys to `conf.ini`
(see the [Cloudreve documentation](https://docs.cloudreve.org)):

```yaml
cloudreve:
  config:
    CORS:
      AllowOrigins: "https://app.example.com"
      AllowCredentials: true
```

To provide the whole `conf.ini` yourself, put it under the key `conf.ini` of a Secret and set
`confini.existingSecret`: the chart then renders no `conf.ini`, and the `cloudreve`, `database` and `redis` values are
ignored.

`CR_SETTING_DEFAULT_*` variables in `extraEnv` seed settings at first install. Do not put secrets in `CR_CONF_*`
variables: Cloudreve logs their values.

### Resources and scheduling

The defaults request 100m CPU and 128 Mi and limit memory to 1 Gi. Thumbnails of large images, videos and office
documents (libvips, FFmpeg, LibreOffice) can need more: raise `resources.limits.memory` if the pod is OOM-killed while
generating them. `nodeSelector`, `tolerations`, `affinity` and `priorityClassName` place the pod.

### Time zone

`timezone` (UTC) sets `TZ` in the container.

## Examples

### PostgreSQL and Redis behind an Ingress

```yaml
database:
  type: postgres
  host: cloudreve-db-rw.databases.svc
  port: 5432
  name: cloudreve
  user: cloudreve
  existingSecret: cloudreve-db
redis:
  enabled: true
  server: valkey.cache.svc:6379
  existingSecret: cloudreve-redis
cloudreve:
  existingSecret: cloudreve-session
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
  - name: CR_SETTING_DEFAULT_siteURL
    value: https://cloud.example.com
```

### SQLite on an existing volume, official image

```yaml
imageProvider: upstream
persistence:
  existingClaim: cloudreve-data
```

## Security

- The pod runs as uid and gid 1000 (`fsGroup` 1000 on the volume), with a read-only root filesystem, no capability,
  no privilege escalation and the `RuntimeDefault` seccomp profile. The service account token is not mounted.
- Secrets reach the container through `secretKeyRef` only. `conf.ini`, which contains them, only exists in a
  memory-backed volume of the pod.
- The chart starts `/cloudreve/cloudreve` directly: the root entrypoint of the official image (aria2 and supervisord)
  never runs. Remote downloads through aria2 are therefore not available.
- Cloudreve listens in plain HTTP: terminate TLS on your Ingress or Gateway.
- Registration settings, storage policies and user groups are managed in the Cloudreve admin panel: review them after
  creating the administrator account.
- The chart creates no NetworkPolicy: restrict traffic to the pod with your own if your cluster enforces them.

## Testing

On every pull request, the repository CI:

- runs `helm lint --strict` with Helm 3 and Helm 4 on the default values and on `ci/default-values.yaml` (SQLite) and
  `ci/upstream-values.yaml` (official image), and validates the rendered manifests with kubeconform;
- installs both values files in a kind cluster with chart-testing, which runs the chart's `helm test`: a pod with the
  Cloudreve image and the same security context calls `/api/v4/site/ping` through the Service;
- runs an end-to-end test (`.github/workflows/e2e.yaml`) with the image built from the same commit: the first account
  signs up and is administrator, logs in, uploads a file, finds it in the listing with its size, downloads the same
  content back, and gets a thumbnail generated for an uploaded image;
- lints the Artifact Hub metadata and checks that this README and `values.schema.json` are generated from the values.

After an install or upgrade:

```bash
helm test my-storage --namespace storage
```

## Operations

- **Backup**: with SQLite and the local storage policy, everything is in the PVC: back up the volume (or
  `/cloudreve/data` from a pod) while the pod is stopped or idle. With a server database, back up the database and
  the volume together.
- **Scaling**: one replica only (in-memory locks, queue and cron jobs). Give it more resources rather than replicas.
- **Logs**: `kubectl --namespace storage logs deploy/my-storage-cloudreve`; `cloudreve.logLevel: debug` for more.
- **Rendered configuration**: `kubectl --namespace storage exec deploy/my-storage-cloudreve -- cat
  /etc/cloudreve/conf.ini` (it contains secrets).

## Upgrading

### To 2026.11.1

No value to change. The default image moves to `ghcr.io/unxwares/cloudreve` (the same Cloudreve version, built from
the release sources with current Go modules on a current Alpine). To keep the official image, set
`imageProvider: upstream`. The UnxWares image has no aria2 and no default time zone: the chart never started aria2
and always sets `TZ`.

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

## Troubleshooting

- **The pod restarts during the first start**: the startup probe allows 5 minutes for the database migrations
  (`startupProbe.failureThreshold`). Check `kubectl logs` and the database connection settings.
- **`render-config` fails**: a Secret or key it reads is missing (`kubectl describe pod`): check `existingSecret` names
  and keys.
- **Uploads fail through the Ingress**: the controller limits the body size; with ingress-nginx set
  `nginx.ingress.kubernetes.io/proxy-body-size: "0"`.
- **Everybody is logged out after each Argo CD sync**: the session secret is regenerated, set
  `cloudreve.existingSecret` or `cloudreve.sessionSecret`.
- **Thumbnails are missing for videos or office files**: watch the pod memory while they are generated, and raise
  `resources.limits.memory` if it is OOM-killed.

## Uninstalling

```bash
helm uninstall my-storage --namespace storage
```

The data PVC carries `helm.sh/resource-policy: keep`: it is not deleted, so a new install with the same release name
finds the data again. The chart Secret is deleted with the release: keep a copy of the session secret if you plan to
reinstall on the same data (or use `cloudreve.existingSecret`). Delete the volume yourself only when the data is no
longer needed: `kubectl --namespace storage delete pvc my-storage-cloudreve`.

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
| image.repository | string | `""` | Cloudreve image repository. Empty: `ghcr.io/unxwares/cloudreve` or `docker.io/cloudreve/cloudreve`, from `imageProvider`. |
| image.tag | string | `""` | Image tag (defaults to the chart appVersion). |
| imageProvider | string | `"unxwares"` | Image provider. `unxwares`: `ghcr.io/unxwares/cloudreve`, Cloudreve built from its release sources with current Go modules on a current Alpine, rebuilt twice a week, signed (https://github.com/UnxWares/helm/tree/main/images). `upstream`: the official `docker.io/cloudreve/cloudreve` image. |
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
| timezone | string | `"UTC"` | Timezone of the container (`TZ`). The upstream image would otherwise default to Asia/Shanghai. |
| tolerations | list | `[]` | Tolerations. |

## Credits

See [CREDITS.md](CREDITS.md).

## License

The chart is released under the MIT license. Cloudreve is licensed under the GPL-3.0.
