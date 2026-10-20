# Taiga Helm Chart

![Version: 2026.10.1](https://img.shields.io/badge/Version-2026.10.1-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 6.10.2](https://img.shields.io/badge/AppVersion-6.10.2-informational?style=flat-square)

[Taiga](https://taiga.io/) is an open-source project management platform for agile teams (Scrum, Kanban, issues,
wiki). This chart deploys the whole stack of [taiga-docker](https://github.com/taigaio/taiga-docker): backend API,
Celery workers, events (websockets), front, protected media, an nginx gateway, two RabbitMQ brokers and, optionally,
a bundled PostgreSQL.

## Features

- **Taiga 6.10** with pinned images, optional **OIDC** login (UnxWares OIDC-enabled front/back images)
- **Generated secrets** (Django key, database and broker passwords) kept across upgrades, or your own Secret;
  passwords reach containers through `secretKeyRef` only, broker URLs are assembled with Kubernetes `$(VAR)` expansion
- **Supported versions**: PostgreSQL 17, RabbitMQ 4.4, nginx 1.30 (the previous release shipped PostgreSQL 12.3,
  RabbitMQ 3.8 and nginx 1.19, all end-of-life)
- **Hardened**: gateway, PostgreSQL and RabbitMQ run as non-root with a read-only root filesystem; the Taiga images
  must start as root (their entrypoints `chown` the volumes then drop to `taiga` with gosu), so they keep only the
  capabilities this needs; seccomp `RuntimeDefault`, no service account token
- **Media that works out of the box**: backend, async workers and gateway share one volume. With a ReadWriteOnce
  volume the chart schedules them on the same node; use ReadWriteMany to spread them
- Ingress or Gateway API HTTPRoute (websockets included)

## Installation

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
helm install taiga unxwares/taiga --namespace taiga --create-namespace \
  --set global.domain=taiga.example.com \
  --set externalDatabase.enabled=false --set db.enabled=true
```

Then create the first administrator:

```bash
kubectl exec -it -n taiga deploy/taiga-backend -- python manage.py createsuperuser
```

Charts are signed: see [verifying signatures](https://github.com/UnxWares/helm/blob/main/SECURITY.md#verifying-chart-signatures).

## Examples

### External PostgreSQL and an Ingress with TLS

```yaml
global:
  domain: taiga.example.com
externalDatabase:
  enabled: true
  host: postgres.databases.svc
  database: taiga
  username: taiga
  existingSecret: taiga-db   # keys: database-host, database-port, database-name, database-username, database-password
  sslmode: require
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    nginx.ingress.kubernetes.io/proxy-body-size: 100m
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
  hosts:
    - host: taiga.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: taiga-example-com-tls
      hosts:
        - taiga.example.com
```

### OIDC (Authentik, Keycloak, ...)

```yaml
global:
  oidc:
    enabled: true
    issuer: https://auth.example.com/application/o/taiga/
    clientId: taiga
    existingSecret: taiga-oidc   # keys: oidc-client-id, oidc-client-secret
```

### SMTP

```yaml
backend:
  email:
    backend: smtp
    host: smtp.example.com
    port: 587
    useTLS: true
    defaultFrom: taiga@example.com
    existingSecret: taiga-smtp   # keys: EMAIL_HOST_USER, EMAIL_HOST_PASSWORD
```

## Notes

- Without `global.persistence.media`, uploads stay in the backend container: they cannot be downloaded through the
  gateway and are lost at the next restart. Keep it enabled.
- Attachments are served by `taiga-protected`, which checks the signed token of each URL (valid `protected.maxAge`
  seconds) before nginx streams the file.
- RabbitMQ 4 refuses the transient non-exclusive queues Celery still declares by default: the chart ships a
  `conf.d` file that re-allows them (`deprecated_features.permit.transient_nonexcl_queues = true`).

## Upgrading

### To 2026.10.1 (Taiga 6.9 → 6.10)

Back up the database and the media volume first.

- **PostgreSQL 12 → 17 (bundled `db` only)**: a major version cannot start on the old data directory, and the data
  now lives in `PGDATA=/var/lib/postgresql/data/pgdata`. Taiga created an `array_agg_mult(anyarray)` aggregate that
  cannot be restored on PostgreSQL 14 or later ([taiga-back#54](https://github.com/taigaio/taiga-back/issues/54)):
  drop it, dump, upgrade, then restore.

  ```bash
  kubectl exec -n taiga deploy/taiga-db -- psql -U taiga -d taiga -c 'DROP AGGREGATE IF EXISTS array_agg_mult(anyarray);'
  kubectl exec -n taiga deploy/taiga-db -- pg_dump -U taiga -Fc taiga > taiga.dump
  # helm upgrade ..., wait for the new database pod, then:
  kubectl exec -i -n taiga deploy/taiga-db -- pg_restore -U taiga -d taiga --clean --if-exists --no-owner < taiga.dump
  kubectl rollout restart -n taiga deploy/taiga-backend deploy/taiga-async
  ```

  The previous release kept the bundled database without a volume by default: persistence is now enabled
  (`db.persistence`).
- **RabbitMQ 3.8 → 4.4**: brokers only hold transient task and event messages; they start fresh in a new `rabbitmq-4`
  sub-path of their volume. `erlangCookie` is ignored (RabbitMQ 4 generates the cookie in its data volume).
- **Secrets**: the former `changeme` defaults are gone. Empty values are generated once and kept; if you relied on
  the defaults, existing sessions are invalidated (new `global.secretKey`). Set the old values explicitly to keep them.
- **Static files**: `global.persistence.static` is removed; the gateway copies the static files from the backend image.
  The former `<release>-static` PVC can be deleted.
- **Media**: `global.persistence.media` is now enabled by default with `ReadWriteOnce`. Existing claims keep their
  access mode.
- **Gateway**: it listens on 8080 as uid 101. A custom `gateway.configMapName` must listen on 8080 too.
- **Telemetry** is now disabled by default (`global.telemetry.enabled`).

## Requirements

Kubernetes: `>=1.27.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| async.affinity | object | `{}` |  |
| async.autoscaling.enabled | bool | `false` |  |
| async.autoscaling.maxReplicas | int | `5` |  |
| async.autoscaling.minReplicas | int | `1` |  |
| async.autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| async.command[0] | string | `"/taiga-back/docker/async_entrypoint.sh"` |  |
| async.extraEnv | list | `[]` |  |
| async.extraEnvFrom | list | `[]` |  |
| async.extraVolumeMounts | list | `[]` |  |
| async.extraVolumes | list | `[]` |  |
| async.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| async.image.repository | string | `"docker.io/taigaio/taiga-back"` | Async (celery) image repository. |
| async.image.tag | string | `"6.10.2"` | Image tag. |
| async.nodeSelector | object | `{}` |  |
| async.podAnnotations | object | `{}` |  |
| async.podLabels | object | `{}` |  |
| async.podSecurityContext | object | `{"fsGroup":999,"fsGroupChangePolicy":"OnRootMismatch","seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. |
| async.replicaCount | int | `1` | Celery worker replicas. |
| async.resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"50m","memory":"256Mi"}}` | Resources. |
| async.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"add":["CHOWN","DAC_OVERRIDE","FOWNER","SETUID","SETGID"],"drop":["ALL"]}}` | Container security context (same entrypoint model as the backend). |
| async.tolerations | list | `[]` |  |
| asyncRabbitmq.affinity | object | `{}` |  |
| asyncRabbitmq.auth.erlangCookie | string | `""` | Deprecated: RabbitMQ 4 ignores the RABBITMQ_ERLANG_COOKIE variable; a cookie is generated in the data volume. |
| asyncRabbitmq.auth.existingSecret | string | `""` | Existing secret with the broker credentials. |
| asyncRabbitmq.auth.password | string | `""` | Broker password. Leave empty to generate one (kept across upgrades). |
| asyncRabbitmq.auth.secretKeys.erlangCookie | string | `"RABBITMQ_ERLANG_COOKIE"` |  |
| asyncRabbitmq.auth.secretKeys.password | string | `"RABBITMQ_PASS"` |  |
| asyncRabbitmq.auth.secretKeys.user | string | `"RABBITMQ_USER"` |  |
| asyncRabbitmq.auth.secretKeys.vhost | string | `"RABBITMQ_VHOST"` |  |
| asyncRabbitmq.auth.user | string | `"taiga"` | Broker user. |
| asyncRabbitmq.auth.vhost | string | `"taiga"` | Virtual host. |
| asyncRabbitmq.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| asyncRabbitmq.image.repository | string | `"docker.io/library/rabbitmq"` | RabbitMQ image. |
| asyncRabbitmq.image.tag | string | `"4.4.0-management-alpine"` | Image tag. |
| asyncRabbitmq.nodeSelector | object | `{}` |  |
| asyncRabbitmq.persistence.accessMode | string | `"ReadWriteOnce"` | Access mode. |
| asyncRabbitmq.persistence.annotations | object | `{}` | PVC annotations. |
| asyncRabbitmq.persistence.enabled | bool | `true` | Persist the broker data. |
| asyncRabbitmq.persistence.existingClaim | string | `""` | Use an existing PVC. |
| asyncRabbitmq.persistence.size | string | `"5Gi"` | Volume size. |
| asyncRabbitmq.persistence.storageClass | string | `""` | Storage class. |
| asyncRabbitmq.podAnnotations | object | `{}` |  |
| asyncRabbitmq.podLabels | object | `{}` |  |
| asyncRabbitmq.podSecurityContext | object | `{"fsGroup":101,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":101,"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context (rabbitmq alpine image user: uid 100, gid 101). |
| asyncRabbitmq.replicaCount | int | `1` | Async broker replicas (keep 1: the chart does not configure a RabbitMQ cluster). |
| asyncRabbitmq.resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"50m","memory":"192Mi"}}` | Resources. |
| asyncRabbitmq.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. |
| asyncRabbitmq.service.managementPort | int | `15672` |  |
| asyncRabbitmq.service.port | int | `5672` |  |
| asyncRabbitmq.service.type | string | `"ClusterIP"` |  |
| asyncRabbitmq.tolerations | list | `[]` |  |
| backend.affinity | object | `{}` |  |
| backend.autoscaling.enabled | bool | `false` |  |
| backend.autoscaling.maxReplicas | int | `5` |  |
| backend.autoscaling.minReplicas | int | `1` |  |
| backend.autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| backend.email.backend | string | `"console"` | Django email backend (`console` or `smtp`). |
| backend.email.defaultFrom | string | `"no-reply@taiga.example.com"` | Sender address. |
| backend.email.existingSecret | string | `""` | Existing secret with the SMTP credentials. |
| backend.email.host | string | `""` | SMTP host. |
| backend.email.password | string | `""` | SMTP password (stored in the chart secret). |
| backend.email.port | int | `25` | SMTP port. |
| backend.email.secretKeys.password | string | `"EMAIL_HOST_PASSWORD"` |  |
| backend.email.secretKeys.user | string | `"EMAIL_HOST_USER"` |  |
| backend.email.useSSL | bool | `false` | Use implicit TLS. |
| backend.email.useTLS | bool | `false` | Use STARTTLS. |
| backend.email.user | string | `""` | SMTP user. |
| backend.extraEnv | list | `[]` |  |
| backend.extraEnvFrom | list | `[]` |  |
| backend.extraVolumeMounts | list | `[]` | Extra volume mounts. |
| backend.extraVolumes | list | `[]` | Extra volumes. |
| backend.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| backend.image.repository | string | `"docker.io/taigaio/taiga-back"` | Backend image repository. |
| backend.image.tag | string | `"6.10.2"` | Image tag. |
| backend.imagePullSecrets | list | `[]` | Image pull secrets (defaults to global.imagePullSecrets). |
| backend.livenessProbe.httpGet.path | string | `"/api/v1/"` |  |
| backend.livenessProbe.httpGet.port | string | `"http"` |  |
| backend.nodeSelector | object | `{}` |  |
| backend.podAnnotations | object | `{}` |  |
| backend.podLabels | object | `{}` |  |
| backend.podSecurityContext | object | `{"fsGroup":999,"fsGroupChangePolicy":"OnRootMismatch","seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. |
| backend.readinessProbe.httpGet.path | string | `"/api/v1/"` |  |
| backend.readinessProbe.httpGet.port | string | `"http"` |  |
| backend.replicaCount | int | `1` | Backend replicas. |
| backend.resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"384Mi"}}` | Resources. |
| backend.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"add":["CHOWN","DAC_OVERRIDE","FOWNER","SETUID","SETGID"],"drop":["ALL"]}}` | Container security context. The image entrypoint runs migrations and `chown` as root, then switches to the `taiga` user (uid 999) with gosu: only the capabilities needed for that are kept. |
| backend.service.port | int | `8000` |  |
| backend.service.type | string | `"ClusterIP"` |  |
| backend.startupProbe | object | `{"failureThreshold":60,"httpGet":{"path":"/api/v1/","port":"http"},"periodSeconds":10}` | Startup probe (the first start runs the database migrations). |
| backend.tolerations | list | `[]` |  |
| db.affinity | object | `{}` |  |
| db.auth.database | string | `"taiga"` | Database name. |
| db.auth.existingSecret | string | `""` | Existing secret holding the user and password (overrides auth.user / auth.password). |
| db.auth.password | string | `""` | Database password. Leave empty to generate one (kept across upgrades). |
| db.auth.secretKeys.password | string | `"POSTGRES_PASSWORD"` |  |
| db.auth.secretKeys.user | string | `"POSTGRES_USER"` |  |
| db.auth.user | string | `"taiga"` | Database user. |
| db.enabled | bool | `false` | Deploy a bundled PostgreSQL (single pod, for small instances; prefer an operator-managed database in production). |
| db.healthcheck.enabled | bool | `true` | Enable the pg_isready probes. |
| db.healthcheck.interval | string | `"10s"` |  |
| db.healthcheck.retries | int | `5` |  |
| db.healthcheck.startPeriod | string | `"5s"` |  |
| db.healthcheck.timeout | string | `"5s"` |  |
| db.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| db.image.repository | string | `"docker.io/library/postgres"` | PostgreSQL image. |
| db.image.tag | string | `"17.11-alpine"` | Image tag. |
| db.nodeSelector | object | `{}` |  |
| db.persistence.accessMode | string | `"ReadWriteOnce"` | Access mode. |
| db.persistence.annotations | object | `{}` | PVC annotations. |
| db.persistence.enabled | bool | `true` | Persist the bundled database. |
| db.persistence.existingClaim | string | `""` | Use an existing PVC. |
| db.persistence.size | string | `"8Gi"` | Volume size. |
| db.persistence.storageClass | string | `""` | Storage class. |
| db.podAnnotations | object | `{}` |  |
| db.podLabels | object | `{}` |  |
| db.podSecurityContext | object | `{"fsGroup":70,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":70,"runAsNonRoot":true,"runAsUser":70,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context (postgres alpine image user: uid/gid 70). |
| db.resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"50m","memory":"128Mi"}}` | Resources. |
| db.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. |
| db.service.port | int | `5432` | Service port. |
| db.service.type | string | `"ClusterIP"` | Service type. |
| db.tolerations | list | `[]` |  |
| events.affinity | object | `{}` |  |
| events.extraEnv | list | `[]` |  |
| events.extraEnvFrom | list | `[]` |  |
| events.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| events.image.repository | string | `"docker.io/taigaio/taiga-events"` | Events image repository. |
| events.image.tag | string | `"6.10.0"` | Image tag. |
| events.livenessProbe | object | `{"httpGet":{"path":"/healthz","port":"health"}}` | Liveness probe (health endpoint on port 3023). |
| events.nodeSelector | object | `{}` |  |
| events.podAnnotations | object | `{}` |  |
| events.podLabels | object | `{}` |  |
| events.podSecurityContext | object | `{"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. |
| events.readinessProbe | object | `{"httpGet":{"path":"/healthz","port":"health"}}` | Readiness probe. |
| events.replicaCount | int | `1` | Events (websockets) replicas. |
| events.resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"20m","memory":"96Mi"}}` | Resources. |
| events.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"add":["CHOWN","DAC_OVERRIDE","FOWNER","SETUID","SETGID"],"drop":["ALL"]}}` | Container security context. The entrypoint renders .env and chowns as root, then switches to uid 99 with su-exec. |
| events.service.port | int | `8888` |  |
| events.service.type | string | `"ClusterIP"` |  |
| events.tolerations | list | `[]` |  |
| eventsRabbitmq.affinity | object | `{}` |  |
| eventsRabbitmq.auth.erlangCookie | string | `""` | Deprecated: RabbitMQ 4 ignores the RABBITMQ_ERLANG_COOKIE variable; a cookie is generated in the data volume. |
| eventsRabbitmq.auth.existingSecret | string | `""` | Existing secret with the broker credentials. |
| eventsRabbitmq.auth.password | string | `""` | Broker password. Leave empty to generate one (kept across upgrades). |
| eventsRabbitmq.auth.secretKeys.erlangCookie | string | `"RABBITMQ_ERLANG_COOKIE"` |  |
| eventsRabbitmq.auth.secretKeys.password | string | `"RABBITMQ_PASS"` |  |
| eventsRabbitmq.auth.secretKeys.user | string | `"RABBITMQ_USER"` |  |
| eventsRabbitmq.auth.secretKeys.vhost | string | `"RABBITMQ_VHOST"` |  |
| eventsRabbitmq.auth.user | string | `"taiga"` | Broker user. |
| eventsRabbitmq.auth.vhost | string | `"taiga"` | Virtual host. taiga-events hard-codes `taiga`: do not change it. |
| eventsRabbitmq.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| eventsRabbitmq.image.repository | string | `"docker.io/library/rabbitmq"` | RabbitMQ image. |
| eventsRabbitmq.image.tag | string | `"4.4.0-management-alpine"` | Image tag. |
| eventsRabbitmq.nodeSelector | object | `{}` |  |
| eventsRabbitmq.persistence.accessMode | string | `"ReadWriteOnce"` | Access mode. |
| eventsRabbitmq.persistence.annotations | object | `{}` | PVC annotations. |
| eventsRabbitmq.persistence.enabled | bool | `true` | Persist the broker data. |
| eventsRabbitmq.persistence.existingClaim | string | `""` | Use an existing PVC. |
| eventsRabbitmq.persistence.size | string | `"5Gi"` | Volume size. |
| eventsRabbitmq.persistence.storageClass | string | `""` | Storage class. |
| eventsRabbitmq.podAnnotations | object | `{}` |  |
| eventsRabbitmq.podLabels | object | `{}` |  |
| eventsRabbitmq.podSecurityContext | object | `{"fsGroup":101,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":101,"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context (rabbitmq alpine image user: uid 100, gid 101). |
| eventsRabbitmq.replicaCount | int | `1` | Events broker replicas (keep 1). |
| eventsRabbitmq.resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"50m","memory":"192Mi"}}` | Resources. |
| eventsRabbitmq.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. |
| eventsRabbitmq.service.managementPort | int | `15672` |  |
| eventsRabbitmq.service.port | int | `5672` |  |
| eventsRabbitmq.service.type | string | `"ClusterIP"` |  |
| eventsRabbitmq.tolerations | list | `[]` |  |
| externalDatabase.database | string | `"postgres"` | Database name. |
| externalDatabase.enabled | bool | `true` | Use an external PostgreSQL database (set `db.enabled` and disable this to use the bundled one). |
| externalDatabase.existingSecret | string | `""` | Existing secret holding the connection settings. |
| externalDatabase.host | string | `"127.0.0.1"` | Database host. |
| externalDatabase.password | string | `""` | Database password (stored in the chart secret). Required unless `existingSecret` is set. |
| externalDatabase.port | int | `5432` | Database port. |
| externalDatabase.secretKeys.database | string | `"database-name"` |  |
| externalDatabase.secretKeys.host | string | `"database-host"` |  |
| externalDatabase.secretKeys.password | string | `"database-password"` |  |
| externalDatabase.secretKeys.port | string | `"database-port"` |  |
| externalDatabase.secretKeys.username | string | `"database-username"` |  |
| externalDatabase.sslmode | string | `"prefer"` | libpq sslmode (`disable`, `require`, `verify-full`...). |
| externalDatabase.username | string | `"user"` | Database user. |
| frontend.affinity | object | `{}` |  |
| frontend.autoscaling.enabled | bool | `false` |  |
| frontend.autoscaling.maxReplicas | int | `5` |  |
| frontend.autoscaling.minReplicas | int | `1` |  |
| frontend.autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| frontend.extraEnv | list | `[]` |  |
| frontend.extraEnvFrom | list | `[]` |  |
| frontend.extraVolumeMounts | list | `[]` |  |
| frontend.extraVolumes | list | `[]` |  |
| frontend.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| frontend.image.repository | string | `"docker.io/taigaio/taiga-front"` | Frontend image repository. |
| frontend.image.tag | string | `"6.10.3"` | Image tag. |
| frontend.imagePullSecrets | list | `[]` | Image pull secrets (defaults to global.imagePullSecrets). |
| frontend.livenessProbe.httpGet.path | string | `"/"` |  |
| frontend.livenessProbe.httpGet.port | string | `"http"` |  |
| frontend.nodeSelector | object | `{}` |  |
| frontend.podAnnotations | object | `{}` |  |
| frontend.podLabels | object | `{}` |  |
| frontend.podSecurityContext | object | `{"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. |
| frontend.readinessProbe.httpGet.path | string | `"/"` |  |
| frontend.readinessProbe.httpGet.port | string | `"http"` |  |
| frontend.replicaCount | int | `1` | Frontend replicas. |
| frontend.resources | object | `{"limits":{"memory":"128Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | Resources. |
| frontend.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"add":["CHOWN","DAC_OVERRIDE","SETUID","SETGID","NET_BIND_SERVICE"],"drop":["ALL"]}}` | Container security context. The image (nginx as root) rewrites conf.json at startup and binds port 80. |
| frontend.service.port | int | `80` |  |
| frontend.service.type | string | `"ClusterIP"` |  |
| frontend.tolerations | list | `[]` |  |
| gateway.affinity | object | `{}` |  |
| gateway.clientMaxBodySize | string | `"100M"` | Maximum upload size. |
| gateway.configMapName | string | `""` | Existing ConfigMap with a custom `default.conf`. |
| gateway.extraVolumeMounts | list | `[]` |  |
| gateway.extraVolumes | list | `[]` |  |
| gateway.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| gateway.image.repository | string | `"docker.io/nginxinc/nginx-unprivileged"` | Gateway image (unprivileged nginx, listens on 8080). |
| gateway.image.tag | string | `"1.30.6-alpine"` | Image tag (nginx stable branch). |
| gateway.livenessProbe.httpGet.path | string | `"/"` |  |
| gateway.livenessProbe.httpGet.port | string | `"http"` |  |
| gateway.nodeSelector | object | `{}` |  |
| gateway.podAnnotations | object | `{}` |  |
| gateway.podLabels | object | `{}` |  |
| gateway.podSecurityContext | object | `{"runAsGroup":101,"runAsNonRoot":true,"runAsUser":101,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context (nginx-unprivileged runs as uid 101). |
| gateway.readinessProbe.httpGet.path | string | `"/"` |  |
| gateway.readinessProbe.httpGet.port | string | `"http"` |  |
| gateway.replicaCount | int | `1` | Gateway (nginx reverse proxy) replicas. |
| gateway.resources | object | `{"limits":{"memory":"128Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | Resources. |
| gateway.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. |
| gateway.service.port | int | `80` |  |
| gateway.service.type | string | `"ClusterIP"` |  |
| gateway.tolerations | list | `[]` |  |
| global.defaultProbes.liveness.failureThreshold | int | `3` |  |
| global.defaultProbes.liveness.initialDelaySeconds | int | `10` |  |
| global.defaultProbes.liveness.periodSeconds | int | `30` |  |
| global.defaultProbes.liveness.timeoutSeconds | int | `5` |  |
| global.defaultProbes.readiness.failureThreshold | int | `3` |  |
| global.defaultProbes.readiness.initialDelaySeconds | int | `5` |  |
| global.defaultProbes.readiness.periodSeconds | int | `10` |  |
| global.defaultProbes.readiness.timeoutSeconds | int | `3` |  |
| global.domain | string | `"taiga.example.com"` | Public domain of Taiga. |
| global.existingSecret | string | `""` | Existing secret used for every service. It must expose all the keys referenced in `secretKeys` (plus POSTGRES_USER/POSTGRES_PASSWORD and RABBITMQ_USER/RABBITMQ_PASS when the bundled services use it). |
| global.extraEnv | list | `[]` | Extra environment variables for every Taiga service. |
| global.extraEnvFrom | list | `[]` | Extra envFrom sources for every Taiga service. |
| global.imagePullSecrets | list | `[]` | Image pull secrets for every pod. |
| global.oidc.backend.overrideImage.digest | string | `"sha256:7724c7934a02d13c2d4f4ca0f04ba09614df2dc19243e1a762606463bc07a316"` | Image digest (pinned: the `latest-oidc` tag moves). |
| global.oidc.backend.overrideImage.name | string | `"ghcr.io/unxwares/taiga-back"` | OIDC-enabled backend image (also used by async). |
| global.oidc.backend.overrideImage.tag | string | `"latest-oidc"` | Image tag. |
| global.oidc.backend.useXForwardedHost | bool | `false` | Enable if running behind reverse proxy with TLS termination. |
| global.oidc.clientId | string | `""` | OIDC client ID. |
| global.oidc.clientSecret | string | `""` | OIDC client secret (stored in the chart secret; ignored with `existingSecret`). |
| global.oidc.enabled | bool | `false` | Enable OIDC login (uses the UnxWares OIDC-enabled front/back images below). |
| global.oidc.endpoints.authorization | string | `""` |  |
| global.oidc.endpoints.jwks | string | `""` |  |
| global.oidc.endpoints.token | string | `""` |  |
| global.oidc.endpoints.userinfo | string | `""` |  |
| global.oidc.existingSecret | string | `""` | Existing secret with the client ID and secret. |
| global.oidc.frontend.buttonText | string | `"Login with SSO"` | Text of the SSO button. |
| global.oidc.frontend.enableDefaultLogin | bool | `true` | Keep the username/password login form. |
| global.oidc.frontend.overrideImage.digest | string | `"sha256:6e3a52da17b8f16d82b972ac47c1c8f14b0639aafc5a5d0957dd796359f72c83"` | Image digest (pinned: the `latest-oidc` tag moves). |
| global.oidc.frontend.overrideImage.name | string | `"ghcr.io/unxwares/taiga-front"` | OIDC-enabled frontend image. |
| global.oidc.frontend.overrideImage.tag | string | `"latest-oidc"` | Image tag. |
| global.oidc.issuer | string | `""` | OIDC issuer URL. |
| global.oidc.scopes | string | `"openid profile email"` | OIDC scopes. |
| global.oidc.secretKeys.clientId | string | `"oidc-client-id"` |  |
| global.oidc.secretKeys.clientSecret | string | `"oidc-client-secret"` |  |
| global.persistence.media.accessMode | string | `"ReadWriteOnce"` | Access mode. With ReadWriteOnce, backend, async and gateway are scheduled on the same node (pod affinity added by the chart); use ReadWriteMany to spread them. An existing claim keeps its original mode. |
| global.persistence.media.annotations | object | `{}` | PVC annotations. |
| global.persistence.media.enabled | bool | `true` | Persist uploaded attachments and exports, shared by backend, async and gateway. Without it, attachments cannot be downloaded and are lost when the backend pod restarts. |
| global.persistence.media.existingClaim | string | `""` | Use an existing PVC. |
| global.persistence.media.size | string | `"5Gi"` | Volume size. |
| global.persistence.media.storageClass | string | `""` | Storage class. |
| global.pod.affinity | object | `{}` | Default affinity for every pod. |
| global.pod.nodeSelector | object | `{}` | Default node selector for every pod. |
| global.pod.tolerations | list | `[]` | Default tolerations for every pod. |
| global.podSecurityContext | object | `{}` | Default pod security context (used when a component does not set its own). |
| global.resources | object | `{}` | Default resources (used when a component does not set its own). |
| global.scheme | string | `"https"` | Public URL scheme (`http` or `https`). |
| global.secretKey | string | `""` | Django secret key shared by back, async, events and protected. Leave empty to generate one (kept across upgrades). |
| global.secretKeys.secretKey | string | `"SECRET_KEY"` | Key of the Django secret key in `existingSecret`. |
| global.securityContext | object | `{}` | Default container security context (used when a component does not set its own). |
| global.serviceAccount.annotations | object | `{}` | Service account annotations. |
| global.serviceAccount.automount | bool | `false` | Taiga never talks to the Kubernetes API: the token is not mounted. |
| global.serviceAccount.create | bool | `true` | Create a dedicated service account. |
| global.serviceAccount.name | string | `""` | Service account name (generated when empty). |
| global.subPath | string | `""` | Sub-path when Taiga is not served at the root of the domain. |
| global.telemetry.enabled | bool | `false` | Send anonymous usage telemetry to Taiga. |
| global.websocketsScheme | string | `"wss"` | Websocket scheme (`ws` or `wss`). |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Expose Taiga through a Gateway API HTTPRoute (to the gateway service). |
| httpRoute.hostnames | list | `[]` | Hostnames (defaults to global.domain when empty). |
| httpRoute.parentRefs | list | `[{"name":"gateway","sectionName":"http"}]` | Gateways this route is attached to. |
| ingress.annotations | object | `{}` | Ingress annotations (websockets must be allowed on /events; raise the body size for uploads). |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Expose Taiga through an Ingress (to the gateway). |
| ingress.hosts | list | `[{"host":"taiga.example.com","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts. |
| ingress.tls | list | `[]` | Ingress TLS. |
| protected.affinity | object | `{}` |  |
| protected.extraEnv | list | `[]` |  |
| protected.extraEnvFrom | list | `[]` |  |
| protected.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| protected.image.repository | string | `"docker.io/taigaio/taiga-protected"` | Protected image repository. |
| protected.image.tag | string | `"6.10.1"` | Image tag. |
| protected.livenessProbe | object | `{"tcpSocket":{"port":"http"}}` | Liveness probe. |
| protected.maxAge | int | `360` | Validity of signed attachment URLs (seconds). |
| protected.nodeSelector | object | `{}` |  |
| protected.podAnnotations | object | `{}` |  |
| protected.podLabels | object | `{}` |  |
| protected.podSecurityContext | object | `{"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. |
| protected.readinessProbe | object | `{"tcpSocket":{"port":"http"}}` | Readiness probe. |
| protected.replicaCount | int | `1` | Protected (signed attachment URLs) replicas. |
| protected.resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"20m","memory":"128Mi"}}` | Resources. |
| protected.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"add":["CHOWN","DAC_OVERRIDE","FOWNER","SETUID","SETGID"],"drop":["ALL"]}}` | Container security context (same entrypoint model as the backend: chown as root, then gosu to uid 999). |
| protected.service.port | int | `8003` |  |
| protected.service.type | string | `"ClusterIP"` |  |
| protected.tolerations | list | `[]` |  |

## License

The chart is released under the MIT license. Taiga is licensed under the MPL-2.0.
