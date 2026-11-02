# FossFLOW Helm Chart

![Version: 2026.11.3](https://img.shields.io/badge/Version-2026.11.3-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 1.0.5](https://img.shields.io/badge/AppVersion-1.0.5-informational?style=flat-square)

[FossFLOW](https://github.com/Abrar74774/FossFLOW) is an open-source Progressive Web App for drawing isometric
infrastructure diagrams. This chart deploys one container running nginx (the web app) and, optionally, a small
Node.js backend that saves the diagrams as JSON files on a persistent volume. By default it runs the UnxWares image,
FossFLOW built from the upstream sources without root and with a read-only root filesystem; the upstream image stays
available. The chart is maintained by UnxWares; FossFLOW itself is maintained by the
[Abrar74774/FossFLOW](https://github.com/Abrar74774/FossFLOW) project, the continuation of the original
`stan-smith/FossFLOW`.

## Features

- **UnxWares image by default**: FossFLOW v1.0.5 built from the upstream sources with updated npm dependencies on a
  current Alpine (see [Images](#images)); the upstream image (`master-2b3cee3`) stays one value away
- Two modes: **server storage** (diagrams saved by the backend on a PVC, the default) or **browser-only** (diagrams
  stay in each user's browser, stateless pods that can be scaled or autoscaled)
- **Hardened pod** with the UnxWares image: uid 1000, read-only root filesystem, every capability dropped, seccomp
  `RuntimeDefault`, no service account token; it meets the `restricted` Pod Security Standard
- **Backend reachable from nginx only**: it listens on `127.0.0.1:3001` (both images), and the UnxWares image sends
  no CORS header to other sites
- Optional NetworkPolicy: only the HTTP port is open, and the pods open no connection
- Probes on the storage backend (`/api/storage/status`) when it is enabled, so a dead backend makes the pod unready
- Ingress or Gateway API HTTPRoute, optional HorizontalPodAutoscaler, `helm test`, an end-to-end test in CI, values
  schema

## Architecture

`<fullname>` is `<release>-fossflow`, or just `<release>` when the release name contains `fossflow`.

| Resource | Name | Created when | Purpose |
|----------|------|--------------|---------|
| Deployment | `<fullname>` | always | Container `fossflow`: nginx serves the web app on port 8080 (UnxWares image) or 80 (upstream image) and proxies `/api/` to the backend on `127.0.0.1:3001`, which runs only with `storage.enabled`. Strategy `Recreate` with a ReadWriteOnce PVC. |
| Service | `<fullname>` | always | `service.type` (ClusterIP), port `service.port` (80) to the container port `http`. The backend port is not in the Service and does not listen on the pod address. |
| PersistentVolumeClaim | `<fullname>` | `storage.enabled`, `persistence.enabled`, no `persistence.existingClaim` | `/data/diagrams`, one `<id>.json` file per diagram; `helm.sh/resource-policy: keep`. |
| ServiceAccount | `<fullname>` | `serviceAccount.create` (default) | No RBAC, token not mounted. |
| Ingress | `<fullname>` | `ingress.enabled` | |
| HTTPRoute | `<fullname>` | `httpRoute.enabled` | Every rule is sent to the Service. |
| HorizontalPodAutoscaler | `<fullname>` | `autoscaling.enabled` | CPU (and optional memory) target on the Deployment. |
| NetworkPolicy | `<fullname>` | `networkPolicy.enabled` | Ingress on the HTTP port only, no egress (see [NetworkPolicy](#networkpolicy)). |
| Pod (test hook) | `<fullname>-test-connection` | `helm test` | See [Testing](#testing). |

Volumes of the pod: `data`, mounted at `/data/diagrams` with `storage.enabled` (the PVC, `persistence.existingClaim`,
or an `emptyDir` when `persistence.enabled=false`), and `tmp` at `/tmp` (`emptyDir`, 256 Mi: the nginx pid and
temporary files of the UnxWares image). The chart creates no Secret, no ConfigMap and no init container.

## Images

The FossFLOW container and the `helm test` pod use the same image, chosen by `imageProvider`:

| `imageProvider` | Image | Notes |
|---|---|---|
| `unxwares` (default) | `ghcr.io/unxwares/fossflow:<appVersion>` | Built from the upstream sources of commit `2b3cee3` (release v1.0.5) with the lockfile of `npm audit fix` (branch [fix/vulnerable-dependencies](https://github.com/UnxWares/FossFLOW/tree/fix/vulnerable-dependencies) of UnxWares/FossFLOW), on a current Alpine without npm, su-exec or openssl. nginx (port 8080) and the backend run as uid 1000 with a read-only root filesystem; the backend listens on `127.0.0.1:3001` and its CORS headers are dropped. Rebuilt twice a week, signed with cosign. |
| `upstream` | `docker.io/abrar74774/fossflow:master-2b3cee3` | Published by the maintainers of [Abrar74774/FossFLOW](https://github.com/Abrar74774/FossFLOW) from its public sources. Starts as root: nginx on port 80, backend through `su-exec`, writable root filesystem (see [Security](#security)). Upstream only publishes `master-<commit>` tags. |

Both images exist for `linux/amd64` and `linux/arm64` and use the same environment variables (`ENABLE_SERVER_STORAGE`,
`STORAGE_PATH`, `BACKEND_HOST`) and the same storage format: switching between them keeps the diagrams. Sources,
build details and the cosign verification command are in
[images/](https://github.com/UnxWares/helm/tree/main/images).

- Another tag or registry: set `image.repository` and `image.tag` (an empty tag means the appVersion for the
  UnxWares image, `master-2b3cee3` for the upstream one). The chart picks the port and the security contexts from
  `imageProvider`, so a custom build of the upstream Dockerfile goes with `imageProvider: upstream`.
- Pin a digest: `image.digest` takes precedence over the tag. Read it with
  `docker buildx imagetools inspect ghcr.io/unxwares/fossflow:1.0.5` (or `crane digest`):

  ```yaml
  image:
    digest: sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  ```

- Known vulnerabilities of both images are tracked daily in the
  [CVE watch issue](https://github.com/UnxWares/helm/issues?q=is%3Aissue+is%3Aopen+label%3Acve-watch).

## Requirements

Kubernetes: `>=1.27.0-0`

- Storage, with the default values (server storage): a default StorageClass, or `persistence.storageClass`, that
  provisions a 1 Gi ReadWriteOnce volume. More than one replica with server storage needs a ReadWriteMany volume.
- Exposure: an Ingress controller, or a Gateway API implementation serving `gateway.networking.k8s.io/v1` HTTPRoutes.
  Otherwise use `kubectl port-forward`.
- Pod Security: with the UnxWares image (default) the pods meet the `restricted` Pod Security Standard. The upstream
  image starts as root and adds back five capabilities: its namespace must allow `baseline` (see
  [Security](#security)).
- Nodes: `amd64` or `arm64`.
- FossFLOW has no user accounts: anything reachable from outside a trusted network needs an authentication layer in
  front (see [Authentication](#authentication)).

## Installation

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
helm install fossflow unxwares/fossflow --namespace fossflow --create-namespace
```

Charts are signed with the UnxWares Helm Charts OpenPGP key (fingerprint
`7902 E52E A435 EF27 C643  2E53 78D6 B532 C599 DA9B`, public key https://helm.unxwares.studio/pgp-public-key.asc).
To verify the package before installing:

```bash
curl -fsSL https://helm.unxwares.studio/pgp-public-key.asc | gpg --import
gpg --export 7902E52EA435EF27C6432E5378D6B532C599DA9B > ~/.gnupg/unxwares-helm.gpg
helm install fossflow unxwares/fossflow --namespace fossflow --create-namespace \
  --verify --keyring ~/.gnupg/unxwares-helm.gpg
```

No value is required: the defaults run FossFLOW with server storage on a 1 Gi PVC, reachable inside the cluster only.
A real install usually adds an Ingress or HTTPRoute with authentication in front (see [Examples](#examples)).

To reach it without exposing it:

```bash
kubectl -n fossflow port-forward svc/fossflow 8080:80
```

then open http://127.0.0.1:8080. There is no login: every user who reaches FossFLOW sees and can change every diagram
saved on the server.

## Configuration

### Storage mode

`storage.enabled=true` (default) starts the Node.js backend with `ENABLE_SERVER_STORAGE=true`,
`STORAGE_PATH=/data/diagrams` and `BACKEND_HOST=127.0.0.1`, so that only nginx, in the same pod, reaches it. The
UnxWares image runs it, like nginx, as `storage.uid`:`storage.gid` (1000:1000); with the upstream image the chart
also sets `PUID`/`PGID` to these values, and the backend drops to them. The backend lists, opens, saves and deletes
diagrams through `/api/diagrams`, as one `<id>.json` file per diagram, shared by every user of the instance. A save
rewrites the whole file: when two users save the same diagram, the last save wins.

`storage.enabled=false` does not start the backend: diagrams only live in the storage of each user's browser, nothing
is kept on the server, and clearing the browser data loses them. The pods are then stateless, and `/api/` answers
`502` (the web app then falls back to the browser storage).

### Persistence

Used only with `storage.enabled`. The diagrams go to a PVC created by the chart (`persistence.size`,
`persistence.storageClass`, `persistence.accessModes`, `persistence.annotations`), or to `persistence.existingClaim`:

```yaml
persistence:
  storageClass: longhorn
  size: 2Gi
```

```yaml
persistence:
  existingClaim: fossflow-diagrams
```

`persistence.enabled=false` keeps the diagrams in an `emptyDir`: they are lost whenever the pod is replaced (upgrade,
node drain, eviction), and each replica has its own.

The pod sets `fsGroup` to `storage.gid` (`fsGroupChangePolicy: OnRootMismatch`), so the volume is group-writable by
that group. With your own `podSecurityContext`, keep `fsGroup` equal to `storage.gid`. Storage that ignores `fsGroup`
(some NFS provisioners) must give write access to `storage.uid`/`storage.gid` itself.

### Scaling

- Server storage on a ReadWriteOnce (or ReadWriteOncePod) volume supports one replica: rendering fails with
  `replicaCount > 1` or `autoscaling.enabled`, and the Deployment uses the `Recreate` strategy (a short downtime on
  each upgrade).
- With a ReadWriteMany volume, several replicas share the same directory:

  ```yaml
  replicaCount: 2
  persistence:
    storageClass: nfs-client
    accessModes:
      - ReadWriteMany
  ```

- Browser-only pods are stateless and can be autoscaled on CPU (`autoscaling.*`, needs metrics-server):

  ```yaml
  storage:
    enabled: false
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 5
    targetCPUUtilizationPercentage: 80
  ```

### Exposure

The Service listens on `service.port` (80) and targets the container port `http` (8080 with the UnxWares image, 80
with the upstream one); `service.type` can be `ClusterIP` (default), `NodePort` or `LoadBalancer`:

```yaml
service:
  type: LoadBalancer
  port: 8080
```

Ingress (`ingress.*`). FossFLOW accepts request bodies up to 10 MB; ingress-nginx limits them to 1 MB by default, so
raise it or saving a large diagram fails with `413`:

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    nginx.ingress.kubernetes.io/proxy-body-size: 10m
  hosts:
    - host: diagrams.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: fossflow-tls
      hosts:
        - diagrams.example.com
```

Gateway API (`httpRoute.*`). The default rule matches every path; the `matches` and `filters` of each rule are copied
and the backend is always the FossFLOW Service:

```yaml
httpRoute:
  enabled: true
  parentRefs:
    - name: public-gateway
      namespace: gateway-system
      sectionName: https
  hostnames:
    - diagrams.example.com
```

### TLS

The pod serves plain HTTP. Terminate TLS at the Ingress (`ingress.tls`, with a certificate Secret or
cert-manager as above) or at the Gateway listener referenced by `httpRoute.parentRefs`.

### Authentication

FossFLOW has no user management. The `HTTP_AUTH_USER`/`HTTP_AUTH_PASSWORD` basic auth of the upstream image does not
work in v1.0.5 (its entrypoint calls `openssl passwd -bcrypt`, which OpenSSL 3 removed), and the UnxWares image
refuses to start when they are set rather than run without the protection they ask for. Protect FossFLOW at the
ingress:

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: fossflow-basic-auth   # htpasswd file in key "auth"
    nginx.ingress.kubernetes.io/auth-realm: FossFLOW
  hosts:
    - host: diagrams.example.com
      paths:
        - path: /
          pathType: Prefix
```

```bash
htpasswd -c auth alice
kubectl -n fossflow create secret generic fossflow-basic-auth --from-file=auth
```

or put it behind an SSO proxy (oauth2-proxy, Authentik outpost...). With an HTTPRoute, use the authentication
features of your Gateway implementation. Authentication at the edge does not cover traffic from inside the cluster:
see [NetworkPolicy](#networkpolicy).

### Resources

Defaults: requests `cpu: 20m` and `memory: 96Mi`, limit `memory: 512Mi`, for nginx and the backend together.

```yaml
resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    memory: 256Mi
```

### Scheduling

`nodeSelector`, `tolerations` and `affinity` are copied to the pod (the chart has no topology spread setting):

```yaml
nodeSelector:
  kubernetes.io/arch: arm64
tolerations:
  - key: dedicated
    operator: Equal
    value: tools
    effect: NoSchedule
```

### NetworkPolicy

The backend listens on `127.0.0.1:3001` only, so other pods cannot reach it. The web app and its `/api/` proxy are
still open to every pod of the cluster on the HTTP port, without your ingress authentication. `networkPolicy.enabled`
creates a NetworkPolicy for the FossFLOW pods:

- ingress only on the HTTP port, from the peers of `networkPolicy.ingressFrom` and the pods of the release (the
  `helm test` pod); with an empty `ingressFrom`, any source may reach the HTTP port;
- no egress at all: FossFLOW opens no connection (the diagrams are files on the volume).

Only let the ingress controller in (adapt the namespace):

```yaml
networkPolicy:
  enabled: true
  ingressFrom:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
```

NetworkPolicies need a network plugin that enforces them (Calico, Cilium, kindnet in recent kind releases...).

### Extra environment, volumes and labels

`extraEnv` and `extraEnvFrom` are added to the container (the chart already sets `ENABLE_SERVER_STORAGE`,
`STORAGE_PATH`, `BACKEND_HOST`, and `PUID`/`PGID` with the upstream image), `volumes`/`volumeMounts` add volumes, `podAnnotations`/`podLabels` go on the
pod and `imagePullSecrets` on the pod spec:

```yaml
podAnnotations:
  backup.velero.io/backup-volumes: data   # Velero file system backup of the diagrams volume
podLabels:
  team: platform
```

## Examples

### Server storage behind ingress-nginx, HTTPS and basic auth

```yaml
# Server storage on a 2 Gi volume, HTTPS through ingress-nginx and cert-manager, basic auth at the ingress, and only
# the ingress controller allowed to reach the pod.
persistence:
  storageClass: longhorn
  size: 2Gi
networkPolicy:
  enabled: true
  ingressFrom:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    nginx.ingress.kubernetes.io/proxy-body-size: 10m
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: fossflow-basic-auth
    nginx.ingress.kubernetes.io/auth-realm: FossFLOW
  hosts:
    - host: diagrams.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: fossflow-tls
      hosts:
        - diagrams.example.com
```

### Browser-only, autoscaled, behind a Gateway

```yaml
# No server storage: diagrams stay in each user's browser, the pods are stateless and autoscaled.
storage:
  enabled: false
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 4
httpRoute:
  enabled: true
  parentRefs:
    - name: public-gateway
      namespace: gateway-system
      sectionName: https
  hostnames:
    - diagrams.example.com
resources:
  requests:
    cpu: 20m
    memory: 64Mi
  limits:
    memory: 128Mi
```

## Security

What the chart does by default, with the UnxWares image:

- **User**: nginx and the backend run as `storage.uid`:`storage.gid` (1000:1000), `runAsNonRoot: true`; nginx listens
  on the unprivileged port 8080.
- **Capabilities and filesystem**: every capability dropped, `allowPrivilegeEscalation: false`, read-only root
  filesystem (nginx writes its pid and temporary files to the `/tmp` `emptyDir`), seccomp profile `RuntimeDefault`.
  The pods meet the `restricted` Pod Security Standard.
- **Backend**: it listens on `127.0.0.1:3001` (`BACKEND_HOST`), so only nginx, in the same pod, reaches it. The
  UnxWares nginx drops the CORS headers of the backend, which allows any origin: another site cannot read or change
  the diagrams through the browser of someone who can reach FossFLOW.
- **Service account**: a dedicated one without RBAC; its token is not mounted (`serviceAccount.automount=false`), and
  no Service environment variables are injected (`enableServiceLinks: false`).
- **Secrets**: the chart handles no credentials and creates no Secret.
- **Exposure**: the Service publishes the HTTP port only (the web app and the `/api/` proxy). The optional
  [NetworkPolicy](#networkpolicy) limits who reaches it and blocks every outgoing connection.

With `imageProvider: upstream`, the entrypoint of the upstream image has to start as root (uid 0): it rewrites the
nginx configuration, starts the nginx master as root to bind port 80 (the workers run as the `nginx` user of the
image) and the backend through `su-exec` as `storage.uid`:`storage.gid`. The chart then drops every capability but
`CHOWN`, `DAC_OVERRIDE`, `SETUID`, `SETGID` and `NET_BIND_SERVICE`, keeps `allowPrivilegeEscalation: false` and
seccomp `RuntimeDefault`, and leaves the root filesystem writable. This fits the `baseline` Pod Security Standard,
not `restricted`. The backend still listens on `127.0.0.1` only (the chart sets `BACKEND_HOST`), but it keeps
answering any origin (CORS `*`).

Caveats:

- FossFLOW has no authentication: whoever reaches the HTTP port can list, read, overwrite and delete every diagram
  saved on the server. Put authentication in front of any exposure (see [Authentication](#authentication)), and
  restrict the other pods with the [NetworkPolicy](#networkpolicy).
- The backend rate limit counts every request as coming from nginx (see [Scaling limits](#scaling-limits)).
- Known vulnerabilities of both images: follow the
  [CVE watch issue](https://github.com/UnxWares/helm/issues?q=is%3Aissue+is%3Aopen+label%3Acve-watch).

## Testing

On every pull request, the repository CI runs for this chart:

- `helm lint --strict` with Helm 3 (v3.22.1) and Helm 4 (v4.3.1), on the default values and on each `ci/*-values.yaml`
  (`ci/default-values.yaml`: server storage on a PVC; `ci/browser-only-values.yaml`: no storage, 2 replicas, the
  NetworkPolicy; `ci/upstream-values.yaml`: the upstream image);
- kubeconform (strict) on the same renders, for Kubernetes 1.31.0 and 1.34.0;
- the Artifact Hub metadata lint (`ah lint`), and a check that `README.md` and `values.schema.json` match what
  `generate-schemas.sh` produces.

When the pull request changes the chart, `ct lint` (chart-testing: lint, YAML lint, version increment check) and
`ct install` run as well: the chart is installed on a kind cluster once per `ci/*-values.yaml` file, and `helm test`
runs after each install.

The test pod, `<fullname>-test-connection`, runs the FossFLOW image as uid 65534 with a read-only root filesystem and
no capabilities, and runs `wget -qO- http://<fullname>:<service.port>/api/storage/status` (with `storage.enabled`) or
`/` (without). It checks that the Service reaches a ready pod, that nginx answers and, with storage, that nginx
reaches the running backend. It changes nothing.

The end-to-end test (`.github/workflows/e2e.yaml`, script `.github/scripts/fossflow-e2e.sh`) builds the UnxWares
image of the commit, loads it into kind and installs the chart twice in a namespace that enforces the `restricted`
Pod Security Standard: with server storage (`ci/default-values.yaml`), and browser-only with the NetworkPolicy
(`ci/browser-only-values.yaml`). After `helm test`, it checks through the Service that:

- the web app, its scripts and its client-side routes are served;
- with server storage: a diagram is created, listed with its name, read back unchanged, updated and read back, and is
  still there after the pod is replaced; the API sends no CORS header to another site, for reads and preflight
  requests;
- in browser-only mode: no backend answers behind `/api/`;
- the container runs without root on a read-only root filesystem;
- from another pod, the HTTP port answers but the backend port 3001 does not (checked on the release without
  NetworkPolicy, so that only the binding of the backend is tested), and a pod that is not an allowed peer of the
  NetworkPolicy reaches nothing.

It does not drive the web app in a browser, and the upstream image is only covered by `ct install` and `helm test`.

After an install:

```bash
helm test fossflow --namespace fossflow --logs
```

Unit tests (`tests/*_test.yaml`, [helm-unittest](https://github.com/helm-unittest/helm-unittest), run by
`.github/workflows/unit.yaml` on pull requests, every push to main and every Tuesday) render the chart without a
cluster and check the security contexts with both image providers, the image selection (`imageProvider`, repository,
tag, digest), the single-replica rule of ReadWriteOnce storage and its message, the storage environment, the probes
on `/api/storage/status`, persistence, the Service, Ingress and HTTPRoute, the NetworkPolicy, the `helm test` pod, the
release notes and the two examples of this README.

## Operations

### Backup and restore

With server storage, the data is the `/data/diagrams` directory (one JSON file per diagram). Snapshot the PVC with
your storage tools (VolumeSnapshot, Velero...), or copy the files:

```bash
POD=$(kubectl -n fossflow get pod -l app.kubernetes.io/name=fossflow,app.kubernetes.io/instance=fossflow \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n fossflow exec "$POD" -- tar czf - -C /data/diagrams . > fossflow-diagrams.tgz
```

Restore into a running pod (the UnxWares image extracts the files as `storage.uid`):

```bash
kubectl -n fossflow exec -i "$POD" -- tar xzf - -C /data/diagrams < fossflow-diagrams.tgz
```

With the upstream image, `tar` runs as root: give the files back to the backend user afterwards with
`kubectl -n fossflow exec "$POD" -- chown -R 1000:1000 /data/diagrams`.

In browser-only mode nothing is stored on the server: each user keeps their own diagrams.

### Scaling limits

One replica with server storage on a ReadWriteOnce volume (see [Scaling](#scaling)). The backend has no locking: with
a ReadWriteMany volume as with a single pod, a diagram saved by two users at once keeps the last save. The backend
rate-limits the API to 200 reads and 50 writes per minute per client address; every request reaches it through the
nginx of the pod, so this limit is shared by all the users of a pod.

### Logs and useful commands

The container log (`kubectl logs`) shows the entrypoint and backend messages. With the UnxWares image it also holds
the nginx access log (without the Kubernetes probes) and error log; the upstream image writes them to files inside the
container (`/var/log/nginx/`). FossFLOW exposes no metrics endpoint and the chart has no ServiceMonitor.

```bash
kubectl -n fossflow logs deploy/fossflow
kubectl -n fossflow exec deploy/fossflow -- ls -ln /data/diagrams
kubectl -n fossflow exec deploy/fossflow -- wget -qO- http://127.0.0.1:8080/api/storage/status   # port 80 with the upstream image
```

The UnxWares image stops nginx and the backend on `SIGTERM`, and the container stops (and is restarted) if the backend
exits. The upstream entrypoint does not forward `SIGTERM`, so a stopping pod waits for `terminationGracePeriodSeconds`
(10 s) before it is killed.

## Upgrading

### To 2026.11.2

- **Default image change**: `abrar74774/fossflow:master-2b3cee3` → `ghcr.io/unxwares/fossflow:1.0.5`, the same
  FossFLOW version without root, on port 8080 and with a read-only root filesystem. The diagrams are kept: the storage
  format is the same, and the files written by the upstream backend already belong to `storage.uid`:`storage.gid`.
  The pod is replaced once. To keep the upstream image, set `imageProvider: upstream`.
- If your values set `image.repository` to `docker.io/abrar74774/fossflow` (or pin its digest), also set
  `imageProvider: upstream`: the chart chooses the port and the security contexts from `imageProvider`, and the
  upstream entrypoint cannot start without root.
- `podSecurityContext` and `securityContext` are now empty by default and filled from `imageProvider`. If your values
  copy the previous defaults (root capabilities), remove them with the UnxWares image.
- The container port is now 8080 with the UnxWares image (the Service port stays `service.port`). A NetworkPolicy of
  your own that allows port 80 on the pods, such as the example of the previous README, must allow 8080 instead; or
  replace it with `networkPolicy.enabled`.
- The backend now listens on `127.0.0.1` with both images: anything that called port 3001 on the pod directly must go
  through the Service (`/api/` on the HTTP port).

### To 2026.10.1

- **Image change**: `stnsmith/fossflow:latest` → `abrar74774/fossflow:master-2b3cee3` (FossFLOW v1.0.5). The original
  `stan-smith/FossFLOW` repository no longer exists and the latest `stnsmith/fossflow` images are built from a private
  repository whose source cannot be verified. To keep the old image anyway, set `image.repository` and pin a digest.
- Server storage is now enabled and persisted by default (`storage.enabled`, `persistence.*`). Diagrams previously stored
  inside the container were lost at each restart.
- The container port is always 80; `service.port` only changes the Service port.

## Troubleshooting

- **`server storage on a ReadWriteOnce volume supports a single replica`** at install or upgrade: `replicaCount > 1`
  or `autoscaling.enabled` with server storage on a ReadWriteOnce volume. Keep one replica, use
  `persistence.accessModes: [ReadWriteMany]`, or set `storage.enabled=false`.
- **No pod, `violates PodSecurity "restricted:latest"`** in `kubectl -n fossflow describe replicaset`: the namespace
  enforces `restricted` and the pod runs the upstream image (`imageProvider: upstream`), which needs `baseline`, or
  custom security contexts (see [Security](#security)).
- **`CrashLoopBackOff`, `HTTP_AUTH_USER and HTTP_AUTH_PASSWORD are not supported by this image`**: remove them from
  `extraEnv`/`extraEnvFrom` and use [ingress authentication](#authentication).
- **`CrashLoopBackOff` after setting `image.repository` to the upstream image**: set `imageProvider: upstream` (see
  [Upgrading](#upgrading)).
- **Pod `Pending`**: the PVC is not bound (`kubectl -n fossflow describe pvc`). Set `persistence.storageClass` or
  create a default StorageClass.
- **Pod running but not ready**: with storage, the probes call `/api/storage/status` through nginx, so the backend is
  not running. Read `kubectl -n fossflow logs deploy/fossflow`.
- **Saving fails**: the backend cannot write `/data/diagrams`. Check the owner and group with
  `kubectl -n fossflow exec deploy/fossflow -- ls -ln /data/diagrams` (see [Persistence](#persistence)). A `413` in
  the browser comes from the body size limit of the ingress (see [Exposure](#exposure)), a `429` from the backend rate
  limit (see [Scaling limits](#scaling-limits)).
- **Diagrams gone after a restart**: `persistence.enabled=false` (emptyDir) or `storage.enabled=false` (browser
  storage only).
- **`HTTP_AUTH_USER`/`HTTP_AUTH_PASSWORD` do not work** with the upstream image: broken there, use
  [ingress authentication](#authentication).
- **`helm test` fails**: `helm test fossflow -n fossflow --logs`, then check that the Service has endpoints:
  `kubectl -n fossflow get endpointslices -l kubernetes.io/service-name=fossflow`.

## Uninstalling

```bash
helm uninstall fossflow --namespace fossflow
```

What stays in the namespace:

- the PVC `<fullname>` created by the chart (`helm.sh/resource-policy: keep`), with every saved diagram. A new install
  with the same release name in the same namespace takes it over again. A PVC given with `persistence.existingClaim`
  is never touched by the chart;
- a `helm test` pod that failed (hook resources are not removed by `helm uninstall`).

To delete the diagrams for good (irreversible; the volume is then released according to its reclaim policy):

```bash
kubectl -n fossflow delete pvc fossflow
kubectl -n fossflow delete pod fossflow-test-connection --ignore-not-found
```

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity rules. |
| autoscaling.enabled | bool | `false` | Enable the HorizontalPodAutoscaler (only without server storage, or with a ReadWriteMany volume). |
| autoscaling.maxReplicas | int | `5` | Maximum replicas. |
| autoscaling.minReplicas | int | `1` | Minimum replicas. |
| autoscaling.targetCPUUtilizationPercentage | int | `80` | Target CPU utilization. |
| autoscaling.targetMemoryUtilizationPercentage | string | `nil` | Target memory utilization. |
| extraEnv | list | `[]` | Extra environment variables. HTTP_AUTH_USER/HTTP_AUTH_PASSWORD do not work: the upstream image fails to build its password file (OpenSSL 3 has no bcrypt) and the UnxWares image refuses to start with them. Protect FossFLOW at the ingress level instead. |
| extraEnvFrom | list | `[]` | Extra envFrom sources. |
| fullnameOverride | string | `""` | Override the full resource names. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Expose FossFLOW through a Gateway API HTTPRoute. |
| httpRoute.hostnames | list | `["chart-example.local"]` | Hostnames. |
| httpRoute.parentRefs | list | `[{"name":"gateway","sectionName":"http"}]` | Gateways this route is attached to. |
| httpRoute.rules | list | `[{"matches":[{"path":{"type":"PathPrefix","value":"/"}}]}]` | Rules (every rule is sent to the FossFLOW service). |
| image.digest | string | `""` | Image digest (`sha256:...`). When set, it takes precedence over the tag. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `""` | Image repository. Empty: `ghcr.io/unxwares/fossflow` or `docker.io/abrar74774/fossflow`, from `imageProvider`. |
| image.tag | string | `""` | Image tag. Empty: the chart appVersion for the UnxWares image, `master-2b3cee3` for the upstream one (upstream only publishes `master-<commit>` tags: `master-2b3cee3` is release v1.0.5). |
| imageProvider | string | `"unxwares"` | Image provider. `unxwares`: `ghcr.io/unxwares/fossflow`, FossFLOW built from the upstream sources with updated dependencies on a current Alpine, rebuilt twice a week, signed (https://github.com/UnxWares/helm/tree/main/images): nginx on port 8080 and the backend run as a non-root user, with a read-only root filesystem. `upstream`: `docker.io/abrar74774/fossflow`, built by the maintained continuation of FossFLOW (github.com/Abrar74774/FossFLOW), which starts as root (nginx on port 80, backend through su-exec) with a writable root filesystem. |
| imagePullSecrets | list | `[]` | Secrets for pulling images from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations (add authentication here, e.g. oauth2-proxy or basic auth). |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Expose FossFLOW through an Ingress. |
| ingress.hosts | list | `[{"host":"chart-example.local","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts. |
| ingress.tls | list | `[]` | Ingress TLS. |
| livenessProbe | object | `{"httpGet":{"path":"/","port":"http"},"periodSeconds":20}` | Liveness probe (same `/api/storage/status` substitution as the readiness probe). |
| nameOverride | string | `""` | Override the chart name. |
| networkPolicy.enabled | bool | `false` | Create a NetworkPolicy: FossFLOW only accepts traffic on its HTTP port and opens no connection (no egress at all). |
| networkPolicy.ingressFrom | list | `[]` | Peers allowed to reach FossFLOW (e.g. your ingress controller). Empty allows any source on the HTTP port; pods of this release are always allowed. |
| nodeSelector | object | `{}` | Node selector. |
| persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes. |
| persistence.annotations | object | `{}` | PVC annotations. |
| persistence.enabled | bool | `true` | Persist the diagrams (/data/diagrams) when `storage.enabled`. |
| persistence.existingClaim | string | `""` | Use an existing PVC. |
| persistence.size | string | `"1Gi"` | Volume size. |
| persistence.storageClass | string | `""` | Storage class (empty uses the cluster default). |
| podAnnotations | object | `{}` | Pod annotations. |
| podLabels | object | `{}` | Pod labels. |
| podSecurityContext | object | `{}` | Pod security context. Empty: the defaults of `imageProvider`, `fsGroup` `storage.gid` and seccomp `RuntimeDefault`, plus `runAsNonRoot` as `storage.uid`:`storage.gid` with the UnxWares image (see Security in the README). |
| readinessProbe | object | `{"httpGet":{"path":"/","port":"http"},"periodSeconds":10}` | Readiness probe. With `storage.enabled` and the default path `/`, the chart probes `/api/storage/status` instead, so a dead backend makes the pod unready. |
| replicaCount | int | `1` | Number of replicas. With server storage on a ReadWriteOnce volume, keep 1. |
| resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"20m","memory":"96Mi"}}` | Resources. |
| securityContext | object | `{}` | Container security context. Empty: the defaults of `imageProvider`. UnxWares image: read-only root filesystem, every capability dropped. Upstream image: its entrypoint must start as root (nginx binds port 80 and rewrites its configuration, the backend is started through su-exec), so every capability is dropped except the five it needs. |
| service.port | int | `80` | Service port (the container listens on 8080 with the UnxWares image, 80 with the upstream one). |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | Service account annotations. |
| serviceAccount.automount | bool | `false` | FossFLOW never talks to the Kubernetes API: the token is not mounted. |
| serviceAccount.create | bool | `true` | Create a dedicated service account. |
| serviceAccount.name | string | `""` | Service account name (generated when empty). |
| storage.enabled | bool | `true` | Save diagrams on the server (Node.js backend + volume). When false, diagrams only live in the browser. |
| storage.gid | int | `1000` | Group of the diagrams (`fsGroup` of the pod; `PGID` with the upstream image). |
| storage.uid | int | `1000` | User that owns the diagrams. The UnxWares image runs nginx and the backend as this user; the upstream image starts as root and drops the backend to it (`PUID`), nginx keeping its own `nginx` user. |
| terminationGracePeriodSeconds | int | `10` | Grace period of the pod. The UnxWares image stops nginx and the backend on SIGTERM; the upstream entrypoint does not forward it, so the pod waits for the whole period. |
| tolerations | list | `[]` | Tolerations. |
| volumeMounts | list | `[]` | Additional volumeMounts on the output Deployment definition. |
| volumes | list | `[]` | Additional volumes on the output Deployment definition. |

## License

The chart is released under the MIT license. FossFLOW is licensed under the MIT license.
