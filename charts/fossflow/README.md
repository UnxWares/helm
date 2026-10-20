# FossFLOW Helm Chart

![Version: 2026.10.1](https://img.shields.io/badge/Version-2026.10.1-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 1.0.5](https://img.shields.io/badge/AppVersion-1.0.5-informational?style=flat-square)

[FossFLOW](https://github.com/Abrar74774/FossFLOW) is an open-source Progressive Web App for drawing beautiful
isometric infrastructure diagrams.

## Features

- Pinned, verifiable image built from the public [Abrar74774/FossFLOW](https://github.com/Abrar74774/FossFLOW) repository
- Optional **server storage** (Node.js backend) persisted in a PVC; or browser-only mode that scales horizontally
- Backend dropped to uid 1000, every capability dropped except the five the image entrypoint needs, seccomp `RuntimeDefault`
- Ingress or Gateway API HTTPRoute, probes on the storage backend, `helm test`

## Installation

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
helm install fossflow unxwares/fossflow --namespace fossflow --create-namespace
```

Charts are signed: see [verifying signatures](https://github.com/UnxWares/helm/blob/main/SECURITY.md#verifying-chart-signatures).

## Authentication

FossFLOW has no user management. The image's `HTTP_AUTH_USER`/`HTTP_AUTH_PASSWORD` basic auth does not work in
v1.0.5 (its entrypoint calls `openssl passwd -bcrypt`, which OpenSSL 3 removed), so protect FossFLOW at the ingress:

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

or put it behind an SSO proxy (oauth2-proxy, Authentik outpost...).

## Upgrading

### To 2026.10.1

- **Image change**: `stnsmith/fossflow:latest` → `abrar74774/fossflow:master-2b3cee3` (FossFLOW v1.0.5). The original
  `stan-smith/FossFLOW` repository no longer exists and the latest `stnsmith/fossflow` images are built from a private
  repository whose source cannot be verified. To keep the old image anyway, set `image.repository` and pin a digest.
- Server storage is now enabled and persisted by default (`storage.enabled`, `persistence.*`). Diagrams previously stored
  inside the container were lost at each restart.
- The container port is always 80; `service.port` only changes the Service port.

## Requirements

Kubernetes: `>=1.27.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity rules. |
| autoscaling.enabled | bool | `false` | Enable the HorizontalPodAutoscaler (only without server storage, or with a ReadWriteMany volume). |
| autoscaling.maxReplicas | int | `5` |  |
| autoscaling.minReplicas | int | `1` |  |
| autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| extraEnv | list | `[]` | Extra environment variables. HTTP_AUTH_USER/HTTP_AUTH_PASSWORD are broken in the upstream image (OpenSSL 3 has no bcrypt): protect FossFLOW at the ingress level instead. |
| extraEnvFrom | list | `[]` | Extra envFrom sources. |
| fullnameOverride | string | `""` | Override the full resource names. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Expose FossFLOW through a Gateway API HTTPRoute. |
| httpRoute.hostnames | list | `["chart-example.local"]` | Hostnames. |
| httpRoute.parentRefs | list | `[{"name":"gateway","sectionName":"http"}]` | Gateways this route is attached to. |
| httpRoute.rules | list | `[{"matches":[{"path":{"type":"PathPrefix","value":"/"}}]}]` | Rules (every rule is sent to the FossFLOW service). |
| image.digest | string | `""` | Image digest (`sha256:...`). When set, it takes precedence over the tag. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"docker.io/abrar74774/fossflow"` | FossFLOW image. `abrar74774/fossflow` is built by the maintained continuation of FossFLOW (github.com/Abrar74774/FossFLOW). |
| image.tag | string | `"master-2b3cee3"` | Image tag. Upstream only publishes `master-<commit>` tags: `master-2b3cee3` is release v1.0.5. |
| imagePullSecrets | list | `[]` | Secrets for pulling images from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations (add authentication here, e.g. oauth2-proxy or basic auth). |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Expose FossFLOW through an Ingress. |
| ingress.hosts | list | `[{"host":"chart-example.local","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts. |
| ingress.tls | list | `[]` | Ingress TLS. |
| livenessProbe | object | `{"httpGet":{"path":"/","port":"http"},"periodSeconds":20}` | Liveness probe (same `/api/storage/status` substitution as the readiness probe). |
| nameOverride | string | `""` | Override the chart name. |
| nodeSelector | object | `{}` | Node selector. |
| persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes. |
| persistence.annotations | object | `{}` | PVC annotations. |
| persistence.enabled | bool | `true` | Persist the diagrams (/data/diagrams) when `storage.enabled`. |
| persistence.existingClaim | string | `""` | Use an existing PVC. |
| persistence.size | string | `"1Gi"` | Volume size. |
| persistence.storageClass | string | `""` | Storage class (empty uses the cluster default). |
| podAnnotations | object | `{}` | Pod annotations. |
| podLabels | object | `{}` | Pod labels. |
| podSecurityContext | object | `{"fsGroup":1000,"fsGroupChangePolicy":"OnRootMismatch","seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. |
| readinessProbe | object | `{"httpGet":{"path":"/","port":"http"},"periodSeconds":10}` | Readiness probe. With `storage.enabled` and the default path `/`, the chart probes `/api/storage/status` instead, so a dead backend makes the pod unready. |
| replicaCount | int | `1` | Number of replicas. With server storage on a ReadWriteOnce volume, keep 1. |
| resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"20m","memory":"96Mi"}}` | Resources. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"add":["CHOWN","DAC_OVERRIDE","SETUID","SETGID","NET_BIND_SERVICE"],"drop":["ALL"]}}` | Container security context. The image entrypoint must start as root (nginx binds port 80 and rewrites its config, the backend is started through su-exec): every capability is dropped except the five it needs. |
| service.port | int | `80` | Service port (the container listens on 80). |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | Service account annotations. |
| serviceAccount.automount | bool | `false` | FossFLOW never talks to the Kubernetes API: the token is not mounted. |
| serviceAccount.create | bool | `true` | Create a dedicated service account. |
| serviceAccount.name | string | `""` | Service account name (generated when empty). |
| storage.enabled | bool | `true` | Save diagrams on the server (Node.js backend + volume). When false, diagrams only live in the browser. |
| storage.gid | int | `1000` |  |
| storage.uid | int | `1000` | User and group the Node.js backend drops to (`PUID`/`PGID`). nginx keeps its own `nginx` user. |
| terminationGracePeriodSeconds | int | `10` | The image entrypoint does not forward SIGTERM: keep the grace period short. |
| tolerations | list | `[]` | Tolerations. |
| volumeMounts | list | `[]` | Additional volumeMounts on the output Deployment definition. |
| volumes | list | `[]` | Additional volumes on the output Deployment definition. |

## License

The chart is released under the MIT license. FossFLOW is licensed under the MIT license.
