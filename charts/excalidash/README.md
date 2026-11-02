# ExcaliDash Helm Chart

![Version: 2026.11.2](https://img.shields.io/badge/Version-2026.11.2-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.6.7](https://img.shields.io/badge/AppVersion-0.6.7-informational?style=flat-square)

[ExcaliDash](https://github.com/ZimengXiong/ExcaliDash) is a self-hosted dashboard and organizer for
[Excalidraw](https://excalidraw.com/) drawings, with live collaboration. This chart, maintained by UnxWares, deploys
its two upstream images on Kubernetes: an nginx frontend that serves the web application and proxies the API, and a
Node.js backend that stores the drawings in SQLite on a persistent volume, or in PostgreSQL.

## Features

- Frontend (nginx) + backend (Node.js) with **persistent SQLite** storage (or PostgreSQL)
- **Generated secrets** (JWT, CSRF, API key pepper) kept across upgrades and reinstalls, or your own Secret
- Local, hybrid or enforced **OIDC** authentication
- **Hardened**: non-root pods (frontend uid 101, backend uid 1001), no capabilities, seccomp `RuntimeDefault`,
  read-only root filesystems, no service account token, optional NetworkPolicy isolating the backend, `Secure`
  cookies behind a proxy that terminates TLS
- Ingress or Gateway API HTTPRoute (WebSockets included), `helm test`, and an end-to-end test in CI
- **Validation**: the chart refuses a second backend replica, a PostgreSQL provider without a PostgreSQL URL, and
  OIDC modes without an issuer, a client ID or an `https://` redirect URI

## Architecture

The names below are those of a release called `excalidash`: resources are named `<release>-excalidash` (or just
`<release>` when the release name already contains `excalidash`, as here, or `fullnameOverride`).

| Resource | Name | Created when | Role |
|----------|------|--------------|------|
| Deployment | `excalidash-frontend` | always | nginx (unprivileged) serving the web application and proxying `/api/` and `/socket.io/` to the backend Service. Container port `8080` (`http`). `frontend.replicaCount` replicas, or the HPA. |
| Service | `excalidash-frontend` | always | `frontend.service.type` (ClusterIP), port `frontend.service.port` (80) to 8080. |
| Deployment | `excalidash-backend` | always | Node.js API and Socket.IO server, always 1 replica, `Recreate` strategy. Container port `backend.service.port` (8000). Init container `copy-app` (see Volumes). |
| Service | `excalidash-backend` | always | `backend.service.type` (ClusterIP), port `backend.service.port` (8000). |
| PersistentVolumeClaim | `excalidash-backend` | `backend.persistence.enabled` (default) and no `backend.persistence.existingClaim` | Mounted on `/app/prisma`. Annotated `helm.sh/resource-policy: keep`. |
| Secret | `excalidash` | always | Generated or given secrets (see [Secrets](#secrets-and-existing-secrets)). Annotated `helm.sh/resource-policy: keep`. |
| ServiceAccount | `excalidash` | `serviceAccount.create` (default) | Used by both Deployments, token not mounted, no RBAC. |
| Ingress | `excalidash` | `ingress.enabled` | Sends `/` (every path) of each host to the frontend Service. |
| HTTPRoute | `excalidash` | `httpRoute.enabled` | Sends each rule to the frontend Service. |
| NetworkPolicy | `excalidash-backend` | `networkPolicy.enabled` | Only the frontend (and the test pod) may reach the backend. |
| HorizontalPodAutoscaler | `excalidash-frontend` | `frontend.autoscaling.enabled` | CPU (and optionally memory) based, frontend only. |
| Pod | `excalidash-test-health` | `helm test` | See [Testing](#testing). |

Volumes:

- Frontend: `/tmp` (emptyDir, 256Mi) for the nginx configuration generated at startup, its pid and temporary files.
- Backend: `/app/prisma` (the PVC, or an emptyDir when `backend.persistence.enabled` is false), `/tmp` (emptyDir,
  1Gi), and `/app/dist` and `/app/uploads` (two directories of the `runtime` emptyDir, 1Gi). At each start the
  backend entrypoint copies the Prisma schema and the migrations of the selected provider into `/app/prisma`, writes
  the JWT and CSRF secrets there (`.jwt_secret`, `.csrf_secret`, mode 600), runs the migrations under a lock
  directory (`.migration-lock`), replaces `/app/dist/generated` with the Prisma client of the provider and changes
  the mode of `/app/uploads` (where imports are staged while they are checked). With SQLite, the database is
  `/app/prisma/db.sqlite`.

The root filesystem of the backend is read-only, so the `copy-app` init container (same image and security context)
first copies the image's `/app/dist` into the `runtime` emptyDir and creates the uploads directory there. There is no
Job or CronJob: migrations run in the backend container before the server starts.

## Images

| Component | Default image | Values |
|-----------|---------------|--------|
| Frontend | `docker.io/zimengxiong/excalidash-frontend:0.6.7` | `frontend.image.*` |
| Backend | `docker.io/zimengxiong/excalidash-backend:0.6.7` | `backend.image.*` |

Both tags default to the chart `appVersion`: keep the frontend and backend tags identical. This chart has no
`imageProvider` value: it runs the images published by the ExcaliDash project, and does not use the UnxWares images
(`ghcr.io/unxwares`, built from [images/](https://github.com/UnxWares/helm/tree/main/images) for other charts). The
images are published for `linux/amd64` and `linux/arm64`.

To pin the images by digest, set `frontend.image.digest` and `backend.image.digest` (the digest takes precedence over
the tag). `docker buildx imagetools inspect docker.io/zimengxiong/excalidash-backend:0.6.7` prints the digest of a
tag.

```yaml
frontend:
  image:
    digest: sha256:<digest of docker.io/zimengxiong/excalidash-frontend:0.6.7>
backend:
  image:
    digest: sha256:<digest of docker.io/zimengxiong/excalidash-backend:0.6.7>
```

To pull from a mirror, change the repositories and set `global.imagePullSecrets` (or `frontend.imagePullSecrets` /
`backend.imagePullSecrets`, which replace the global list for one component). The `helm test` pod runs the frontend
image with the frontend pull secrets and pull policy.

```yaml
global:
  imagePullSecrets:
    - name: registry-mirror
frontend:
  image:
    repository: registry.example.com/mirror/excalidash-frontend
backend:
  image:
    repository: registry.example.com/mirror/excalidash-backend
```

Both images are scanned every day by the
[CVE watch](https://github.com/UnxWares/helm/issues?q=is%3Aissue+is%3Aopen+label%3Acve-watch); chart releases that
only bump an image for vulnerabilities are flagged `containsSecurityUpdates` on Artifact Hub.

## Requirements

Kubernetes: `>=1.27.0-0`

- **Storage**: with the default `backend.persistence`, a `ReadWriteOnce` volume of 1Gi from the default
  StorageClass, or from `backend.persistence.storageClass`.
- **Exposure**: an Ingress controller or a Gateway API implementation (`HTTPRoute` `gateway.networking.k8s.io/v1`)
  that passes WebSockets (live collaboration uses Socket.IO on `/socket.io/`), or a `LoadBalancer`/`NodePort`
  Service. The frontend nginx accepts request bodies up to 50 MB: raise the limit of your proxy to match.
- **Optional external services**: a PostgreSQL database, an OpenID Connect provider, and (through
  `backend.extraEnv`) an SMTP server or an S3-compatible bucket.
- **Nodes**: `linux/amd64` or `linux/arm64`.
- **Pod Security**: every pod meets the `restricted` standard (the frontend sysctl
  `net.ipv4.ip_unprivileged_port_start` is in the safe set).
- **NetworkPolicy**: `networkPolicy.enabled` only has an effect with a CNI that enforces NetworkPolicies.

## Installation

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
helm install excalidash unxwares/excalidash --namespace excalidash --create-namespace \
  --set frontend.url=https://draw.example.com
```

Charts are signed with the UnxWares Helm Charts OpenPGP key (fingerprint
`7902 E52E A435 EF27 C643  2E53 78D6 B532 C599 DA9B`, public key
https://helm.unxwares.studio/pgp-public-key.asc). To check the signature at install time:

```bash
curl -fsSL https://helm.unxwares.studio/pgp-public-key.asc | gpg --import
gpg --export 7902E52EA435EF27C6432E5378D6B532C599DA9B > ~/.gnupg/unxwares-helm.gpg
helm install excalidash unxwares/excalidash --namespace excalidash --create-namespace \
  --set frontend.url=https://draw.example.com \
  --verify --keyring ~/.gnupg/unxwares-helm.gpg
```

See [verifying signatures](https://github.com/UnxWares/helm/blob/main/SECURITY.md#verifying-chart-signatures) for
details.

The only value a real install needs is `frontend.url`, the URL users open (the default,
`https://excalidash.example.com`, is a placeholder):

```yaml
frontend:
  url: https://draw.example.com
```

Behind an Ingress or a Gateway that terminates TLS, see [Exposure](#exposure) and [TLS](#tls-and-proxies) (set
`backend.trustProxy: "2"` for per-client rate limits). For a quick test through a port-forward, the URL must be the
local one, since an `https` URL makes the backend redirect plain HTTP requests to it:

```bash
helm install excalidash unxwares/excalidash --namespace excalidash --create-namespace \
  --set frontend.url=http://localhost:8080
kubectl -n excalidash rollout status deploy/excalidash-backend
kubectl -n excalidash port-forward svc/excalidash-frontend 8080:80
```

In `local` mode (the default), open the application right after the install: the first page asks whether to enable
authentication, and **the first visitor decides**. Once it is enabled, the backend prints a one-time setup code in
its logs (valid 15 minutes) and the first administrator registers with it:

```bash
kubectl -n excalidash logs deploy/excalidash-backend | grep -i setup
```

In the OIDC modes, the first user to log in through the provider becomes administrator (see
[Authentication and SSO](#authentication-and-sso)).

## Configuration

### Public URL

`frontend.url` becomes `FRONTEND_URL` of the backend: the origin it accepts, the base of its redirects and of the
default OIDC redirect URI. When it starts with `https://`, the backend redirects every request that did not arrive
over HTTPS (according to `X-Forwarded-Proto`, which the frontend nginx forwards) to that URL, except `/health`.

### Persistence

`/app/prisma` holds the SQLite database (`db.sqlite`), the migrations and the migration lock. It is a PVC by default:

```yaml
backend:
  persistence:
    enabled: true
    storageClass: fast-ssd
    size: 5Gi
    # or reuse an existing PVC (the chart then creates none):
    # existingClaim: excalidash-data
```

The PVC carries `helm.sh/resource-policy: keep`: `helm uninstall` leaves it in place. With
`backend.persistence.enabled: false`, `/app/prisma` is an emptyDir: SQLite data is lost when the backend restarts
(NOTES print a warning), which is fine with PostgreSQL.

### Database

SQLite is the default (`backend.database.provider: sqlite`, URL `file:/app/prisma/db.sqlite`): keep any SQLite URL
under `/app/prisma`. It supports the single backend replica the chart runs anyway.

PostgreSQL: set the provider and the URL, as a value (stored in the chart Secret) or in your own Secret:

```yaml
backend:
  database:
    provider: postgresql
    existingSecret: excalidash-db      # key: database-url = postgresql://user:pass@host:5432/excalidash
```

```yaml
backend:
  database:
    provider: postgresql
    url: postgresql://excalidash:s3cr3t@db-rw.databases.svc:5432/excalidash
  persistence:
    enabled: false
```

`backend.database.secretKeys.url` names the key in `existingSecret` (`database-url` by default). The chart refuses
`provider: postgresql` without a `postgres...` URL or an existing Secret, and cannot check the content of the Secret.
The database must exist; the backend runs `prisma migrate deploy` at each start.

### Exposure

Everything goes through the frontend Service: its nginx serves the application and proxies `/api/` and `/socket.io/`
to the backend Service, so the backend never needs to be exposed. `frontend.service.port` (80) only changes the
Service port: the container listens on 8080.

```yaml
frontend:
  url: http://draw.internal.example.com:30080
  service:
    type: NodePort
```

Ingress: set `ingress.enabled`, `ingress.className`, `ingress.hosts` (only `host` is used: the chart always routes
`/` with `pathType: Prefix`) and `ingress.tls` (see [Ingress with TLS](#ingress-with-tls)). The Ingress controller
must pass WebSockets and accept large bodies (ingress-nginx:
`nginx.ingress.kubernetes.io/proxy-body-size: 50m`).

Gateway API: set `httpRoute.enabled`, `httpRoute.parentRefs` (the default, `gateway`/`http`, is a placeholder),
`httpRoute.hostnames` and `httpRoute.rules` (`matches` and `filters`; each rule is sent to the frontend Service):

```yaml
frontend:
  url: https://draw.example.com
backend:
  trustProxy: "2"
httpRoute:
  enabled: true
  parentRefs:
    - name: main-gateway
      namespace: gateway-system
      sectionName: https
  hostnames:
    - draw.example.com
```

### TLS and proxies

The chart does not terminate TLS: do it in the Ingress controller or the Gateway, and set `frontend.url` to the
`https://` URL. `backend.trustProxy` (`TRUST_PROXY`) tells the backend how many proxies in front of it to trust for
`X-Forwarded-*` headers:

- `"1"` (default): trusts the frontend nginx of the chart, which is always in front of the backend. The backend
  takes the scheme from `X-Forwarded-Proto`, which nginx passes on from the proxy in front of it: behind an Ingress
  or a Gateway that terminates TLS, cookies get the `Secure` flag. The address its rate limits see is the one nginx
  sees: the client with a `NodePort` or `LoadBalancer` Service, the Ingress controller behind an Ingress (all users
  then share one bucket).
- `"2"`: also trusts one proxy in front of the frontend (your Ingress controller or Gateway), so that rate limits see
  the real client address. Use it behind an Ingress or a Gateway that sets `X-Forwarded-For` and
  `X-Forwarded-Proto`.
- `"false"`: trusts no header. The backend sees every request as plain HTTP coming from the frontend pod: cookies
  never get the `Secure` flag, and one rate limit bucket counts all users together.

A value higher than the real number of proxies lets clients choose the address the backend sees, with forged
headers. A client that sends `X-Forwarded-Proto: https` itself over plain HTTP only gets `Secure` cookies that its
browser will not send back. Without `networkPolicy.enabled`, other pods can reach the backend directly and choose the
address it sees, whatever the value: enable the NetworkPolicy.

### Secrets and existing Secrets

The chart Secret `excalidash` holds:

| Key | Source value | Generated when empty | Your own Secret instead |
|-----|--------------|----------------------|-------------------------|
| `jwt-secret` | `backend.secrets.jwtSecret` | yes, 64 characters | `backend.secrets.existingSecret` (same three keys) |
| `csrf-secret` | `backend.secrets.csrfSecret` | yes, 64 characters | `backend.secrets.existingSecret` |
| `api-key-hash-pepper` | `backend.secrets.apiKeyHashPepper` | yes, 64 characters | `backend.secrets.existingSecret` |
| `database-url` | `backend.database.url` | no (default SQLite URL) | `backend.database.existingSecret` + `backend.database.secretKeys.url` |
| `oidc-client-secret` | `backend.auth.oidc.clientSecret` | no | `backend.auth.oidc.existingSecret` + `backend.auth.oidc.existingSecretKey` |

Generated values are read back from the existing Secret at each `helm upgrade` (Helm `lookup`), so they stay the
same across upgrades. A new JWT secret logs everybody out; a new API key pepper invalidates every API key, so never
change it once API keys exist.

**GitOps**: generated secrets cannot be read back by tools that render templates offline (Argo CD...), which would
rotate them on every sync. Use your own Secret, with the keys `jwt-secret`, `csrf-secret` and `api-key-hash-pepper`:

```yaml
backend:
  secrets:
    existingSecret: excalidash-app   # keys: jwt-secret, csrf-secret, api-key-hash-pepper
```

```bash
kubectl -n excalidash create secret generic excalidash-app \
  --from-literal=jwt-secret="$(openssl rand -hex 32)" \
  --from-literal=csrf-secret="$(openssl rand -hex 32)" \
  --from-literal=api-key-hash-pepper="$(openssl rand -hex 32)"
```

The backend restarts when a secret given as a value changes (checksum annotation), not when the content of your own
Secret changes: run `kubectl -n excalidash rollout restart deploy/excalidash-backend` after rotating it.

### Authentication and SSO

`backend.auth.mode` (`AUTH_MODE`):

| Mode | Behaviour |
|------|-----------|
| `local` (default) | Email/password accounts. The first administrator registers with the setup code from the backend logs. |
| `hybrid` | Local accounts and OpenID Connect. The first administrator logs in through OIDC (see below), then creates local accounts from the administration page. |
| `oidc_enforced` | OpenID Connect only. |
| `disabled` | No authentication at all: every request runs as one shared local user. Never expose it. |

In `hybrid` and `oidc_enforced` modes, the chart passes `OIDC_PROVIDER_NAME` (`providerName`, default `SSO`),
`OIDC_ISSUER_URL`, `OIDC_CLIENT_ID`, `OIDC_REDIRECT_URI` and, when `clientSecret` or `existingSecret` is set,
`OIDC_CLIENT_SECRET`. The redirect URI defaults to `<frontend.url>/api/auth/oidc/callback`: register it at the
provider.

```yaml
backend:
  auth:
    mode: oidc_enforced
    oidc:
      providerName: Authentik
      issuerUrl: https://auth.example.com/application/o/excalidash/
      clientId: excalidash
      existingSecret: excalidash-oidc   # key: oidc-client-secret
```

ExcaliDash provisions users at their first OIDC login and, while no account exists yet, makes the first of them an
administrator (`OIDC_FIRST_USER_ADMIN`, on by default): limit who can use the application at the provider. In
`hybrid` mode, ExcaliDash 0.6.7 prints no setup code on a new database (it only issues one once authentication was
turned on at the `local` onboarding), so local registration of the first administrator fails with `Bootstrap setup
code is unavailable or expired`: create the first administrator through OIDC.

The backend refuses to start in production with an `http://` OIDC redirect URI, so the chart requires
`backend.auth.oidc.clientId`, `backend.auth.oidc.issuerUrl` and an `https://` `frontend.url` (or
`backend.auth.oidc.redirectUri`) in these modes. Other
OIDC settings go through `backend.extraEnv`, for example `OIDC_SCOPES`, `OIDC_GROUPS_CLAIM`, `OIDC_ADMIN_GROUPS`,
`OIDC_JIT_PROVISIONING` or `OIDC_FIRST_USER_ADMIN` (see the
[ExcaliDash documentation](https://github.com/ZimengXiong/ExcaliDash/tree/main/docs)):

```yaml
frontend:
  url: https://draw.example.com
backend:
  auth:
    mode: hybrid
    oidc:
      providerName: Keycloak
      issuerUrl: https://sso.example.com/realms/main
      clientId: excalidash
      existingSecret: excalidash-oidc
  extraEnv:
    - name: OIDC_ADMIN_GROUPS
      value: excalidash-admins
```

### Email, file storage and other settings

The chart only sets the variables above. Everything else ExcaliDash reads from its environment (email for password
resets, S3 storage for files, scheduled backups, rate limits, upload sizes...) goes through `backend.extraEnv` and
`backend.extraEnvFrom`, with secrets from a Secret:

```yaml
backend:
  extraEnv:
    - name: MAIL_TRANSPORT
      value: smtp
    - name: MAIL_FROM
      value: ExcaliDash <draw@example.com>
    - name: SMTP_HOST
      value: smtp.example.com
    - name: SMTP_PORT
      value: "587"
    - name: SMTP_USER
      value: draw@example.com
    - name: SMTP_PASSWORD
      valueFrom:
        secretKeyRef:
          name: excalidash-smtp
          key: password
  extraEnvFrom:
    - secretRef:
        name: excalidash-s3     # S3_BUCKET, S3_ENDPOINT, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY...
```

The variable names and their meaning are listed in the
[ExcaliDash documentation](https://github.com/ZimengXiong/ExcaliDash/tree/main/docs). Do not set the variables the
chart already manages (`PORT`, `FRONTEND_URL`, `DATABASE_*`, `JWT_SECRET`, `CSRF_SECRET`, `API_KEY_HASH_PEPPER`,
`AUTH_MODE`, `OIDC_*` above, `TRUST_PROXY`, `NODE_ENV`).

### Resources and probes

Defaults: the frontend requests `10m`/`32Mi` with a `128Mi` memory limit, the backend `50m`/`192Mi` with a `1Gi`
limit.

```yaml
backend:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 1Gi
```

The frontend probes `GET /` on its HTTP port. The backend probes `GET /health` (which checks the database): startup
every 5 s for up to 5 minutes (migrations, with a 120 s lock timeout, run before the server starts), then liveness
every 30 s and readiness every 10 s. Each probe can be replaced as a whole (`frontend.livenessProbe`,
`backend.startupProbe`...).

### Scaling

The backend keeps the Socket.IO state in memory: the chart always runs one backend pod, replaced with the `Recreate`
strategy, and refuses `backend.replicaCount > 1` or `backend.autoscaling.enabled`. The frontend is stateless and can
scale:

```yaml
frontend:
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 5
    targetCPUUtilizationPercentage: 80
    targetMemoryUtilizationPercentage: 80   # optional, of the memory request
```

### Scheduling

`global.pod.nodeSelector`, `global.pod.tolerations` and `global.pod.affinity` apply to both Deployments;
`frontend.nodeSelector`, `frontend.tolerations`, `frontend.affinity` and the `backend.*` equivalents replace them for
one component (they are not merged). The chart has no topology spread or priority class setting.

```yaml
global:
  pod:
    nodeSelector:
      kubernetes.io/arch: arm64
    tolerations:
      - key: dedicated
        operator: Equal
        value: tools
        effect: NoSchedule
frontend:
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            topologyKey: kubernetes.io/hostname
            labelSelector:
              matchLabels:
                app.kubernetes.io/name: excalidash
                app.kubernetes.io/component: frontend
```

### NetworkPolicy

`networkPolicy.enabled: true` creates one policy, on the backend: only the frontend pods and the test pod of the
release may reach its HTTP port. The frontend has no policy (it is the entry point), and egress is not restricted
(OIDC provider, PostgreSQL, SMTP, S3).

```yaml
networkPolicy:
  enabled: true
```

### Monitoring

The chart creates no ServiceMonitor and ExcaliDash exposes no Prometheus metrics. `GET /api/health` on the frontend
Service reaches the backend `/health`, which checks the database: an external probe can watch it.

### Extra environment and volumes

`frontend.extraEnv`, `frontend.extraEnvFrom`, `frontend.volumes`, `frontend.volumeMounts` and their `backend.*`
equivalents are added to each container. For example, to let the backend trust an internal certificate authority
(OIDC provider, S3 endpoint):

```yaml
backend:
  extraEnv:
    - name: NODE_EXTRA_CA_CERTS
      value: /etc/excalidash/ca/ca.crt
  volumes:
    - name: internal-ca
      configMap:
        name: internal-ca
  volumeMounts:
    - name: internal-ca
      mountPath: /etc/excalidash/ca
      readOnly: true
```

## Examples

### Ingress with TLS

```yaml
frontend:
  url: https://draw.example.com
backend:
  trustProxy: "2"   # two trusted hops: your ingress controller, then the frontend nginx
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    nginx.ingress.kubernetes.io/proxy-body-size: 50m
  hosts:
    - host: draw.example.com
  tls:
    - secretName: draw-example-com-tls
      hosts:
        - draw.example.com
networkPolicy:
  enabled: true
```

### OIDC (Authentik, Keycloak, ...)

```yaml
backend:
  auth:
    mode: oidc_enforced
    oidc:
      providerName: Authentik
      issuerUrl: https://auth.example.com/application/o/excalidash/
      clientId: excalidash
      existingSecret: excalidash-oidc   # key: oidc-client-secret
```

### PostgreSQL

```yaml
backend:
  database:
    provider: postgresql
    existingSecret: excalidash-db      # key: database-url = postgresql://user:pass@host:5432/excalidash
```

## Security

What the chart does by default:

- **Users**: the frontend runs as uid/gid 101 (nginx-unprivileged), the backend as uid/gid 1001 (`nodejs`), both
  with `runAsNonRoot` and a matching `fsGroup`.
- **Containers**: read-only root filesystems (the writable paths are the volumes listed in
  [Architecture](#architecture)), `allowPrivilegeEscalation: false`, every capability dropped, seccomp
  `RuntimeDefault`. The frontend listens on 8080 (its image also opens port 80, allowed by the safe sysctl
  `net.ipv4.ip_unprivileged_port_start=80` instead of a capability). Every pod, the test pod included, meets the Pod
  Security Standard `restricted`.
- **Kubernetes API**: the service account token is not mounted (`serviceAccount.automount: false`), and the chart
  creates no Role.
- **Secrets**: JWT, CSRF, API key pepper, database URL and OIDC client secret reach the backend through
  `secretKeyRef`, never as plain values in the pod spec. See [Secrets](#secrets-and-existing-secrets).
- **Network**: both Services are `ClusterIP` until you change them or add an Ingress or an HTTPRoute, which only
  point at the frontend. `networkPolicy.enabled` keeps every other pod away from the backend.
- **Cookies**: `backend.trustProxy: "1"` gives the session and CSRF cookies the `Secure` flag when the proxy in front
  of the frontend reports HTTPS (see [TLS and proxies](#tls-and-proxies)).

What is exposed, and to whom: the frontend serves the application, the API (`/api/`) and the collaboration socket
(`/socket.io/`) to anyone who reaches it; authentication is enforced by the backend according to
`backend.auth.mode`.

Caveats:

- The backend entrypoint rewrites its Prisma client under `/app/dist` at every start, so the backend runs its
  compiled code from a copy in an emptyDir that its own user can write (as in the image, where `/app/dist` belongs
  to that user): a compromised backend process could change that code until the pod is recreated. The init
  container makes a fresh copy from the image at each pod start.
- The entrypoint writes the JWT and CSRF secrets into `/app/prisma` (mode 600), and ExcaliDash backups contain a full
  copy of the database: treat volume snapshots and backup files as secrets.
- `backend.auth.mode: disabled` turns authentication off. In `local` mode, the first visitor of a new installation
  chooses whether authentication is enabled at all; then anyone who can read the backend logs can claim the
  administrator account with the setup code. In OIDC modes, the first user to log in while no account exists
  becomes administrator by default.
- With `backend.trustProxy: "false"`, session cookies are set without the `Secure` flag behind a proxy that
  terminates TLS (see [TLS and proxies](#tls-and-proxies)).
- The chart runs the upstream images, whose known vulnerabilities are tracked in the
  [CVE watch](https://github.com/UnxWares/helm/issues?q=is%3Aissue+is%3Aopen+label%3Acve-watch).

Report security problems as described in [SECURITY.md](https://github.com/UnxWares/helm/blob/main/SECURITY.md).

## Testing

Every pull request of the [repository](https://github.com/UnxWares/helm) runs, for this chart:

- `helm lint --strict` with Helm 3 and Helm 4, on the default values and on `ci/default-values.yaml`;
- kubeconform (strict) on the manifests rendered with the same values, for Kubernetes 1.31 and 1.34;
- `ct lint` (chart-testing: `Chart.yaml` schema, YAML lint, `helm lint`, version increment);
- `ct install` on a kind cluster with `ci/default-values.yaml` (`frontend.url: http://localhost:8080`, SQLite on a
  1Gi PVC, NetworkPolicy on), which installs the chart and runs its `helm test`;
- the Artifact Hub lint (`ah lint`) and a check that `README.md` and `values.schema.json` match `values.yaml`.

`ct lint` and `ct install` only run when the pull request changes the chart.

The `helm test` pod (`templates/tests/test-health.yaml`) runs `wget` from the frontend image against
`http://excalidash-frontend:<frontend.service.port>/api/health`. The request takes the same path as a browser: the
frontend nginx proxies it to the backend `/health`, which checks the database. The test passes when the frontend,
the proxy to the backend (through the NetworkPolicy when enabled) and the database all work. It changes nothing, so
it is safe on a real instance. After an install:

```bash
helm test excalidash -n excalidash --logs
```

The end-to-end test (`.github/workflows/e2e.yaml`, script `.github/scripts/excalidash-e2e.sh`) runs on pull requests
that change the chart, on every push to main and every week. It installs the chart in kind with
`ci/default-values.yaml` and the upstream images, runs `helm test`, then, through the frontend Service like a
browser:

- authentication is turned on at onboarding, the backend logs a setup code, and the first administrator registers
  with it (not with a wrong one) and logs in;
- cookies have no `Secure` flag over plain HTTP, and have it when the request says it came through a proxy that
  terminated TLS (`X-Forwarded-Proto: https`, `backend.trustProxy`);
- an invalid drawing is refused, a valid one is created, listed and read back;
- the `.excalidash` export is an archive with the drawing, and the import check accepts it (the upload is staged in
  `/app/uploads`, writable although the root filesystem is read-only);
- another pod reaches the frontend but not the backend (NetworkPolicy);
- after `helm uninstall` and a new install, the session opened before is still valid (kept JWT secret), the
  administrator logs in with the same password and the drawing is still there (kept PVC).

It does not test live collaboration (Socket.IO), OIDC, PostgreSQL, S3 storage, email or scheduled backups.

## Operations

### Backup and restore

With SQLite, ExcaliDash can write consistent copies of its database itself, on a schedule, into a directory of the
volume (its default directory, `/app/backups`, is on the read-only root filesystem):

```yaml
backend:
  extraEnv:
    - name: BACKUP_SCHEDULE
      value: "0 3 * * *"         # cron, 5 or 6 fields, container time (UTC by default)
    - name: BACKUP_DIR
      value: /app/prisma/backups
    - name: BACKUP_RETENTION_DAYS
      value: "14"
```

Copy them out of the cluster regularly:

```bash
POD=$(kubectl -n excalidash get pod -l app.kubernetes.io/instance=excalidash,app.kubernetes.io/component=backend \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n excalidash cp "$POD:/app/prisma/backups" ./excalidash-backups
```

To restore, copy a backup next to the live database, then point the backend at it with `backend.database.url` in
your values and upgrade: the backend is recreated on the restored file, and the old one stays on the volume.

```bash
kubectl -n excalidash cp ./excalidash-backups/excalidash-sqlite-2026-11-02T03-00-00-000Z.db \
  "$POD:/app/prisma/restored.sqlite"
```

```yaml
backend:
  database:
    url: file:/app/prisma/restored.sqlite
```

Volume snapshots of the `excalidash-backend` PVC (CSI `VolumeSnapshot`, Velero...) are another option. With
PostgreSQL, back up the database with `pg_dump`; with S3 storage, back up the bucket too. Also keep the chart Secret
(or your own): the API key pepper must stay the same for API keys to keep working.

### Scaling limits

- Backend: one pod, enforced by the chart, replaced with the `Recreate` strategy: the application is unavailable
  while the backend restarts (upgrades included), and live sessions reconnect afterwards.
- Frontend: as many replicas as needed (`frontend.replicaCount` or the HPA).

### Logs and useful commands

```bash
kubectl -n excalidash logs deploy/excalidash-backend      # migrations, setup code, requests
kubectl -n excalidash logs deploy/excalidash-frontend     # nginx
kubectl -n excalidash exec deploy/excalidash-frontend -- wget -qO- http://localhost:8080/api/health
kubectl -n excalidash rollout restart deploy/excalidash-backend
```

## Upgrading

Read the notes of every version between yours and the target, back up the database (see
[Backup and restore](#backup-and-restore)), then run `helm upgrade` with your values file:

```bash
helm repo update
helm upgrade excalidash unxwares/excalidash -n excalidash -f values.yaml
```

### To 2026.11.2

- `backend.trustProxy` now defaults to `"1"` instead of `"false"`. `"1"` trusts the chart's own frontend nginx, which
  is always the hop in front of the backend: behind an Ingress or a Gateway that terminates TLS, the backend now sees
  HTTPS and sets its session and CSRF cookies with the `Secure` flag (they had none before). Nothing to do unless you
  set it yourself: keep `"2"` if you use it behind an Ingress, and set `"false"` only to get the previous behaviour.
- The backend root filesystem is now read-only. An init container, `copy-app`, copies `/app/dist` into an emptyDir
  that also holds `/app/uploads`. If your `backend.extraEnv` makes the backend write elsewhere in the container, move
  that path to a volume: `BACKUP_DIR` must point into `/app/prisma` (for example `/app/prisma/backups`), or the
  scheduled backups fail. To go back, set `backend.securityContext.readOnlyRootFilesystem: false`.
- The `excalidash` Secret (generated JWT and CSRF secrets, API key pepper) is now kept on `helm uninstall`, like the
  PVC. Delete it yourself when you remove ExcaliDash for good (see [Uninstalling](#uninstalling)).
- In the OIDC modes the chart now also requires `backend.auth.oidc.clientId`, and an `https://` redirect URI in
  production (the backend did not start without it).

### To 2026.10.1 (ExcaliDash 0.4.27 → 0.6.5)

- The SQLite database now lives in a PVC mounted at `/app/prisma` (`backend.persistence`). Previous releases had no
  volume, so their data was lost at each restart anyway; if you mounted your own volume through `backend.volumes`,
  set `backend.persistence.existingClaim` to it instead.
- `TRUST_PROXY` and `AUTH_MODE` moved from `backend.extraEnv` to `backend.trustProxy` and `backend.auth.mode`.
- `backend.autoscaling` must stay disabled; `backend.database.enabled` is gone (the URL is always set).
- The Ingress now sends every path to the frontend, which proxies `/api` and `/socket.io` to the backend.

## Troubleshooting

**`helm install` fails with an `execution error`**: the chart refuses `backend.replicaCount > 1`,
`backend.autoscaling.enabled`, `provider: postgresql` without a PostgreSQL URL or existing Secret, and the OIDC modes
without `backend.auth.oidc.issuerUrl`, without `backend.auth.oidc.clientId`, or with an `http://` redirect URI in
production.

**No setup code in the logs, or it expired**: in `local` mode the code is printed once authentication is enabled on
the first page, and only while no administrator exists (in `hybrid` mode ExcaliDash 0.6.7 prints none: see
[Authentication and SSO](#authentication-and-sso)). Restart the backend to get a new one:

```bash
kubectl -n excalidash rollout restart deploy/excalidash-backend
kubectl -n excalidash rollout status deploy/excalidash-backend
kubectl -n excalidash logs deploy/excalidash-backend | grep -i setup
```

**The browser is redirected to the `https://` URL, or login fails**: `frontend.url` must be the URL in the browser
(scheme, host and port). Behind a proxy that terminates TLS, the proxy must send `X-Forwarded-Proto: https`.

**`Rate limit exceeded` for every user**: behind an Ingress with `backend.trustProxy: "1"` (or with `"false"`), all
requests seem to come from the Ingress controller (or the frontend pod) and share one rate limit bucket. Set
`trustProxy: "2"` (see [TLS and proxies](#tls-and-proxies)).

**The backend logs `EROFS: read-only file system`**: something writes outside the volumes, usually the scheduled
backups with the default `BACKUP_DIR`. Point `BACKUP_DIR` into `/app/prisma` (see
[Backup and restore](#backup-and-restore)) or mount a volume through `backend.volumes`.

**`413 Request Entity Too Large` on large drawings or imports**: raise the body size limit of the Ingress controller
or Gateway (the frontend nginx accepts 50 MB).

**Live collaboration does not update other browsers**: the proxy in front of the frontend does not pass WebSockets
on `/socket.io/`, or closes idle connections too early.

**The backend restarts with `Timed out waiting for migration lock after 120s`**: a previous start was killed during
the migrations and left its lock directory on the volume. Remove it while the new pod waits for it:

```bash
kubectl -n excalidash exec deploy/excalidash-backend -- rmdir /app/prisma/.migration-lock
```

**The backend is not ready**: `/health` fails when the database is unreachable. Check the logs, the database URL and
that `backend.database.provider` matches it.

**Everybody is logged out, or API keys stopped working**: the generated secrets changed, usually because a GitOps
tool renders the chart offline, or after a reinstall. Use your own Secret (see
[Secrets](#secrets-and-existing-secrets)).

**The PVC stays `Pending`**: there is no default StorageClass, or it cannot provide `ReadWriteOnce`. Check with
`kubectl -n excalidash describe pvc excalidash-backend` and set `backend.persistence.storageClass`.

## Uninstalling

```bash
helm uninstall excalidash -n excalidash
```

This deletes the Deployments, Services, ServiceAccount, Ingress/HTTPRoute, NetworkPolicy and HPA. It keeps, annotated
`helm.sh/resource-policy: keep`:

- the `excalidash-backend` PVC (SQLite database, backups written there);
- the `excalidash` Secret, generated JWT, CSRF and API key pepper included.

It never touches the PVC and Secrets you created yourself (`existingClaim`, `existingSecret`). The chart creates no
StatefulSet, so no other PVC is left behind. A new install under the same release name and namespace takes the kept
PVC and Secret over again: sessions and API keys keep working. To delete the data and the secrets for good:

```bash
kubectl -n excalidash delete pvc excalidash-backend
kubectl -n excalidash delete secret excalidash
```

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| backend.affinity | object | `{}` | Affinity (defaults to global.pod.affinity). |
| backend.auth.mode | string | `"local"` | Authentication mode: `local`, `hybrid` (local + OIDC), `oidc_enforced` or `disabled`. |
| backend.auth.oidc.clientId | string | `""` | OIDC client ID. |
| backend.auth.oidc.clientSecret | string | `""` | OIDC client secret (stored in the chart secret; ignored with `existingSecret`). |
| backend.auth.oidc.existingSecret | string | `""` | Existing secret holding the client secret. |
| backend.auth.oidc.existingSecretKey | string | `"oidc-client-secret"` | Key of the client secret in `existingSecret`. |
| backend.auth.oidc.issuerUrl | string | `""` | OIDC issuer URL. |
| backend.auth.oidc.providerName | string | `""` | Name shown on the login button. |
| backend.auth.oidc.redirectUri | string | `""` | Redirect URI (defaults to `<frontend.url>/api/auth/oidc/callback`). |
| backend.autoscaling.enabled | bool | `false` | Not supported (single backend replica); kept for compatibility, must stay false. |
| backend.autoscaling.maxReplicas | int | `1` | Unused, kept for compatibility. |
| backend.autoscaling.minReplicas | int | `1` | Unused, kept for compatibility. |
| backend.autoscaling.targetCPUUtilizationPercentage | int | `80` | Unused, kept for compatibility. |
| backend.database.existingSecret | string | `""` | Existing secret holding the database URL (overrides `url`). |
| backend.database.provider | string | `"sqlite"` | Database provider: `sqlite` (stored in the persistent volume) or `postgresql`. |
| backend.database.secretKeys.url | string | `"database-url"` | Key of the URL in `existingSecret`. |
| backend.database.url | string | `"file:/app/prisma/db.sqlite"` | Database URL. For sqlite keep a path under /app/prisma; for postgresql use a postgresql:// URL (stored in the chart secret). |
| backend.extraEnv | list | `[]` | Extra environment variables (SMTP, S3 storage, backups, rate limits...). See the ExcaliDash docs. |
| backend.extraEnvFrom | list | `[]` | Extra envFrom sources (e.g. a secret with SMTP or S3 credentials). |
| backend.image.digest | string | `""` | Image digest (takes precedence over the tag). |
| backend.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| backend.image.repository | string | `"docker.io/zimengxiong/excalidash-backend"` | Backend image repository. |
| backend.image.tag | string | `""` | Image tag (defaults to the chart appVersion). |
| backend.imagePullSecrets | list | `[]` | Image pull secrets (defaults to global.imagePullSecrets). |
| backend.livenessProbe | object | `{"httpGet":{"path":"/health","port":"http"},"periodSeconds":30,"timeoutSeconds":10}` | Liveness probe (`/health` checks the database). |
| backend.nodeEnv | string | `"production"` | NODE_ENV. |
| backend.nodeSelector | object | `{}` | Node selector (defaults to global.pod.nodeSelector). |
| backend.persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes. |
| backend.persistence.annotations | object | `{}` | PVC annotations. |
| backend.persistence.enabled | bool | `true` | Persist /app/prisma (SQLite database, migrations lock). Without it, data is lost when the pod restarts. |
| backend.persistence.existingClaim | string | `""` | Use an existing PVC. |
| backend.persistence.size | string | `"1Gi"` | Volume size. |
| backend.persistence.storageClass | string | `""` | Storage class (empty uses the cluster default). |
| backend.podAnnotations | object | `{}` | Pod annotations. |
| backend.podLabels | object | `{}` | Pod labels. |
| backend.podSecurityContext | object | `{"fsGroup":1001,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":1001,"runAsNonRoot":true,"runAsUser":1001,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context (the image runs as `nodejs`, uid 1001). |
| backend.readinessProbe | object | `{"httpGet":{"path":"/health","port":"http"},"periodSeconds":10,"timeoutSeconds":10}` | Readiness probe. |
| backend.replicaCount | int | `1` | Backend replicas. Socket.IO keeps its state in memory: the chart only supports 1. |
| backend.resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"50m","memory":"192Mi"}}` | Resources. |
| backend.secrets.apiKeyHashPepper | string | `""` | Pepper used to hash API keys. Never change it once API keys exist. |
| backend.secrets.csrfSecret | string | `""` | CSRF secret. |
| backend.secrets.existingSecret | string | `""` | Existing secret with the keys `jwt-secret`, `csrf-secret` and `api-key-hash-pepper` (overrides the values above). |
| backend.secrets.jwtSecret | string | `""` | JWT signing secret (32+ characters). |
| backend.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context, also used by the `copy-app` init container. The entrypoint rewrites `/app/dist/generated` and changes the mode of `/app/uploads` at every start: the chart mounts writable copies of both from an emptyDir, so the root filesystem stays read-only. |
| backend.service.port | int | `8000` | Backend port (also used for the PORT environment variable). |
| backend.service.type | string | `"ClusterIP"` | Backend service type. |
| backend.startupProbe | object | `{"failureThreshold":60,"httpGet":{"path":"/health","port":"http"},"periodSeconds":5}` | Startup probe (database migrations run at startup, with a 120 s lock timeout). |
| backend.tolerations | list | `[]` | Tolerations (defaults to global.pod.tolerations). |
| backend.trustProxy | string | `"1"` | `TRUST_PROXY`: how many proxies in front of the backend it trusts for `X-Forwarded-*` headers. `"1"` trusts the frontend nginx, always in front of it: cookies get the `Secure` flag when the proxy in front of the frontend says HTTPS (`X-Forwarded-Proto`). `"2"` also trusts your Ingress controller or Gateway, so that rate limits see the real client address. `"false"` trusts none (cookies never `Secure`, one rate limit bucket for everybody). |
| backend.volumeMounts | list | `[]` | Additional volume mounts. |
| backend.volumes | list | `[]` | Additional volumes. |
| frontend.affinity | object | `{}` | Affinity (defaults to global.pod.affinity). |
| frontend.autoscaling.enabled | bool | `false` | Enable the frontend HorizontalPodAutoscaler. |
| frontend.autoscaling.maxReplicas | int | `5` | Maximum number of frontend replicas. |
| frontend.autoscaling.minReplicas | int | `1` | Minimum number of frontend replicas. |
| frontend.autoscaling.targetCPUUtilizationPercentage | int | `80` | Target average CPU utilization (%). |
| frontend.autoscaling.targetMemoryUtilizationPercentage | string | `nil` | Target average memory utilization (%), relative to the memory request. Null leaves memory out. |
| frontend.extraEnv | list | `[]` | Extra environment variables. |
| frontend.extraEnvFrom | list | `[]` | Extra envFrom sources. |
| frontend.image.digest | string | `""` | Image digest (takes precedence over the tag). |
| frontend.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| frontend.image.repository | string | `"docker.io/zimengxiong/excalidash-frontend"` | Frontend image repository. Keep the frontend and backend tags identical. |
| frontend.image.tag | string | `""` | Image tag (defaults to the chart appVersion). |
| frontend.imagePullSecrets | list | `[]` | Image pull secrets (defaults to global.imagePullSecrets). |
| frontend.livenessProbe | object | `{"httpGet":{"path":"/","port":"http"}}` | Liveness probe. |
| frontend.nodeSelector | object | `{}` | Node selector (defaults to global.pod.nodeSelector). |
| frontend.podAnnotations | object | `{}` | Pod annotations. |
| frontend.podLabels | object | `{}` | Pod labels. |
| frontend.podSecurityContext | object | `{"fsGroup":101,"runAsGroup":101,"runAsNonRoot":true,"runAsUser":101,"seccompProfile":{"type":"RuntimeDefault"},"sysctls":[{"name":"net.ipv4.ip_unprivileged_port_start","value":"80"}]}` | Pod security context. The image (nginx-unprivileged, uid 101) also listens on port 80, which needs the `net.ipv4.ip_unprivileged_port_start` sysctl (in the Kubernetes "safe" set) when running without capabilities. |
| frontend.readinessProbe | object | `{"httpGet":{"path":"/","port":"http"}}` | Readiness probe. |
| frontend.replicaCount | int | `1` | Frontend replicas (stateless nginx, can scale). |
| frontend.resources | object | `{"limits":{"memory":"128Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | Resources. |
| frontend.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. |
| frontend.service.port | int | `80` | Frontend service port (the container listens on 8080). |
| frontend.service.type | string | `"ClusterIP"` | Frontend service type. |
| frontend.tolerations | list | `[]` | Tolerations (defaults to global.pod.tolerations). |
| frontend.url | string | `"https://excalidash.example.com"` | Public URL of ExcaliDash (used by the backend for redirects, cookies and OIDC). An https URL makes the backend redirect plain HTTP requests. |
| frontend.volumeMounts | list | `[]` | Additional volume mounts. |
| frontend.volumes | list | `[]` | Additional volumes. |
| fullnameOverride | string | `""` | Override the full resource names. |
| global.imagePullSecrets | list | `[]` | Default image pull secrets for every pod. |
| global.pod.affinity | object | `{}` | Default affinity for every pod. |
| global.pod.nodeSelector | object | `{}` | Default node selector for every pod. |
| global.pod.tolerations | list | `[]` | Default tolerations for every pod. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Expose ExcaliDash through a Gateway API HTTPRoute. |
| httpRoute.hostnames | list | `["chart-example.local"]` | Hostnames. |
| httpRoute.parentRefs | list | `[{"name":"gateway","sectionName":"http"}]` | Gateways this route is attached to. |
| httpRoute.rules | list | `[{"matches":[{"path":{"type":"PathPrefix","value":"/"}}]}]` | Rules (every rule is sent to the frontend service). |
| ingress.annotations | object | `{}` | Ingress annotations (WebSockets must be allowed for live collaboration). |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Expose ExcaliDash through an Ingress (everything goes to the frontend, which proxies /api and /socket.io). |
| ingress.hosts | list | `[{"host":"chart-example.local"}]` | Ingress hosts. |
| ingress.tls | list | `[]` | Ingress TLS. |
| nameOverride | string | `""` | Override the chart name. |
| networkPolicy.enabled | bool | `false` | Create NetworkPolicies: the backend only accepts traffic from the frontend. |
| serviceAccount.annotations | object | `{}` | Service account annotations. |
| serviceAccount.automount | bool | `false` | ExcaliDash never talks to the Kubernetes API: the token is not mounted. |
| serviceAccount.create | bool | `true` | Create a dedicated service account. |
| serviceAccount.name | string | `""` | Service account name (generated when empty). |

## License

The chart is released under the MIT license. ExcaliDash is licensed under the LGPL-3.0.
