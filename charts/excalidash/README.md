# ExcaliDash Helm Chart

![Version: 2026.10.3](https://img.shields.io/badge/Version-2026.10.3-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.6.7](https://img.shields.io/badge/AppVersion-0.6.7-informational?style=flat-square)

[ExcaliDash](https://github.com/ZimengXiong/ExcaliDash) is a self-hosted dashboard and organizer for
[Excalidraw](https://excalidraw.com/) drawings, with live collaboration.

## Features

- Frontend (nginx) + backend (Node.js) with **persistent SQLite** storage (or PostgreSQL)
- **Generated secrets** (JWT, CSRF, API key pepper) kept across upgrades, or your own Secret
- Local, hybrid or enforced **OIDC** authentication
- **Hardened**: non-root pods (frontend uid 101, backend uid 1001), no capabilities, seccomp `RuntimeDefault`,
  read-only root filesystem for the frontend, no service account token, optional NetworkPolicy isolating the backend
- Ingress or Gateway API HTTPRoute (WebSockets included), `helm test`

## Installation

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
helm install excalidash unxwares/excalidash --namespace excalidash --create-namespace \
  --set frontend.url=https://draw.example.com
```

In `local` auth mode, the first admin is created with a setup code printed in the backend logs (valid 15 minutes).
Charts are signed: see [verifying signatures](https://github.com/UnxWares/helm/blob/main/SECURITY.md#verifying-chart-signatures).

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
  hosts:
    - host: draw.example.com
  tls:
    - secretName: draw-example-com-tls
      hosts:
        - draw.example.com
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

## Notes

- The frontend image also listens on port 80 as an unprivileged user: the chart sets the
  `net.ipv4.ip_unprivileged_port_start=80` pod sysctl, part of the Kubernetes "safe" set.
- The backend runs a single replica (Socket.IO keeps its state in memory); the frontend can scale.

## Upgrading

### To 2026.10.1 (ExcaliDash 0.4.27 → 0.6.5)

- The SQLite database now lives in a PVC mounted at `/app/prisma` (`backend.persistence`). Previous releases had no
  volume, so their data was lost at each restart anyway; if you mounted your own volume through `backend.volumes`,
  set `backend.persistence.existingClaim` to it instead.
- `TRUST_PROXY` and `AUTH_MODE` moved from `backend.extraEnv` to `backend.trustProxy` and `backend.auth.mode`.
- `backend.autoscaling` must stay disabled; `backend.database.enabled` is gone (the URL is always set).
- The Ingress now sends every path to the frontend, which proxies `/api` and `/socket.io` to the backend.

## Requirements

Kubernetes: `>=1.27.0-0`

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
| backend.autoscaling.maxReplicas | int | `1` |  |
| backend.autoscaling.minReplicas | int | `1` |  |
| backend.autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
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
| backend.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}` | Container security context. The entrypoint regenerates files under /app at every start, so the root filesystem stays writable. |
| backend.service.port | int | `8000` | Backend port (also used for the PORT environment variable). |
| backend.service.type | string | `"ClusterIP"` | Backend service type. |
| backend.startupProbe | object | `{"failureThreshold":60,"httpGet":{"path":"/health","port":"http"},"periodSeconds":5}` | Startup probe (database migrations run at startup, with a 120 s lock timeout). |
| backend.tolerations | list | `[]` | Tolerations (defaults to global.pod.tolerations). |
| backend.trustProxy | string | `"false"` | Trust X-Forwarded-* headers. Only enable it when a trusted proxy (your ingress) sanitizes them. |
| backend.volumeMounts | list | `[]` | Additional volume mounts. |
| backend.volumes | list | `[]` | Additional volumes. |
| frontend.affinity | object | `{}` | Affinity (defaults to global.pod.affinity). |
| frontend.autoscaling.enabled | bool | `false` | Enable the frontend HorizontalPodAutoscaler. |
| frontend.autoscaling.maxReplicas | int | `5` |  |
| frontend.autoscaling.minReplicas | int | `1` |  |
| frontend.autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
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
