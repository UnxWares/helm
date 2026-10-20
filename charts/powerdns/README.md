# PowerDNS Helm Chart

![Version: 2026.10.1](https://img.shields.io/badge/Version-2026.10.1-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 5.1.4](https://img.shields.io/badge/AppVersion-5.1.4-informational?style=flat-square)

[PowerDNS Authoritative Server](https://doc.powerdns.com/authoritative/) with its REST API, packaged for
Kubernetes by UnxWares, with an optional [PowerDNS Recursor](https://doc.powerdns.com/recursor/).

## Features

- **Authoritative DNS** with DNSSEC, on SQLite (single replica + PVC), PostgreSQL or MySQL/MariaDB (scale out).
- **Automatic schema creation**: the schema shipped in the PowerDNS image is applied when the database is empty (idempotent init container).
- **REST API** for [ExternalDNS](https://kubernetes-sigs.github.io/external-dns/), PowerDNS-Admin, cert-manager webhooks... The API key is generated and kept across upgrades, or read from your own Secret.
- **Optional Recursor** that forwards your zones to the authoritative server and resolves everything else (DNSSEC validation on).
- **Hardened by default**: non-root (uid 953), read-only root filesystem, every capability dropped, seccomp `RuntimeDefault`, no service account token. DNS listens on an unprivileged port inside the pod and the Service exposes it on 53.
- **Secrets never land in ConfigMaps**: they are injected as environment variables and rendered at startup into a memory-backed volume.
- **Prometheus** `/metrics` with optional ServiceMonitors, **NetworkPolicy** isolating the API, PodDisruptionBudget, HPA (SQL backends), topology spread.

## Installation

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
helm install dns unxwares/powerdns --namespace dns --create-namespace
```

Charts are signed: see [verifying signatures](https://github.com/UnxWares/helm/blob/main/SECURITY.md#verifying-chart-signatures)
and add `--verify --keyring <keyring>` to `helm install`.

## Examples

### Expose DNS outside the cluster

```yaml
service:
  type: LoadBalancer
  externalTrafficPolicy: Local   # keep client IPs (ACLs, AXFR)
config:
  default-soa-content: ns1.example.com. hostmaster.@ 0 10800 3600 604800 3600
```

### PostgreSQL backend with 3 replicas

```yaml
backend:
  type: gpgsql
  gpgsql:
    host: pdns-db-rw.databases.svc
    dbname: pdns
    user: pdns
    existingSecret: pdns-db        # key: password
    extraConnectionParameters: "sslmode=require"
replicaCount: 3
podDisruptionBudget:
  enabled: true
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: powerdns
        app.kubernetes.io/component: authoritative
```

### ExternalDNS

```yaml
# ExternalDNS values
provider:
  name: pdns
extraArgs:
  - --pdns-server=http://dns-powerdns-api.dns.svc:8081
env:
  - name: EXTERNAL_DNS_PDNS_API_KEY
    valueFrom:
      secretKeyRef:
        name: dns-powerdns
        key: api-key
```

Allow ExternalDNS through the NetworkPolicy:

```yaml
networkPolicy:
  enabled: true
  apiAllowedFrom:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: external-dns
```

### Recursor for the cluster

```yaml
recursor:
  enabled: true
  authoritativeZones:
    - example.com
    - 10.in-addr.arpa
  # forwardZonesRecurse: ["9.9.9.9:53"]   # use an upstream resolver instead of the root servers
```

### Managing zones

Zones created through the API are served immediately. With `pdnsutil`, ask the server to refresh its zone cache:

```bash
kubectl exec -n dns deploy/dns-powerdns -c pdns -- \
  sh -c 'pdnsutil zone create example.com ns1.example.com && pdns_control rediscover'
```

## Notes

- **GitOps**: when the API key is generated, tools that render templates offline (Argo CD...) cannot read it back and would rotate it on every sync. Set `api.key` or `api.existingSecret`.
- **gsqlite3** supports a single replica; the chart refuses `replicaCount > 1` or the HPA with it.
- **IPv6**: remove `[::]` from `dns.listenAddresses` (and `::` from `recursor.listenAddresses`) if your pods have IPv6 disabled.
- `webserver.allowFrom` and `recursor.allowFrom` default to private ranges; add your pod CIDR if it uses another range (e.g. `100.64.0.0/10`).

## Requirements

Kubernetes: `>=1.27.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity rules. |
| api.enabled | bool | `true` | Enable the REST API (used by ExternalDNS, PowerDNS-Admin, cert-manager webhooks...). Requires `webserver.enabled`. |
| api.existingSecret | string | `""` | Existing secret holding the API key. |
| api.existingSecretKey | string | `"api-key"` | Key of the API key in `existingSecret`. |
| api.key | string | `""` | API key. Leave empty to generate one (kept across upgrades). Set it explicitly, or use `existingSecret`, with GitOps tools that render templates offline. |
| apiService.annotations | object | `{}` | Service annotations. |
| apiService.port | int | `8081` | API/webserver service port. |
| apiService.type | string | `"ClusterIP"` | API/webserver service type. Keep it internal; expose it through an authenticated ingress if needed. |
| autoscaling.enabled | bool | `false` | Enable the HorizontalPodAutoscaler (gpgsql/gmysql backends only). |
| autoscaling.maxReplicas | int | `6` |  |
| autoscaling.minReplicas | int | `2` |  |
| autoscaling.targetCPUUtilizationPercentage | int | `75` |  |
| backend.dnssec | bool | `true` | Store DNSSEC keys and metadata in the database (`<backend>-dnssec=yes`). |
| backend.gmysql.dbname | string | `"pdns"` | Database name. |
| backend.gmysql.existingSecret | string | `""` | Existing secret holding the database password. |
| backend.gmysql.existingSecretPasswordKey | string | `"password"` | Key of the password in `existingSecret`. |
| backend.gmysql.host | string | `""` | MySQL/MariaDB host. |
| backend.gmysql.password | string | `""` | Database password (ignored when `existingSecret` is set). |
| backend.gmysql.port | int | `3306` | MySQL/MariaDB port. |
| backend.gmysql.user | string | `"pdns"` | Database user. |
| backend.gpgsql.dbname | string | `"pdns"` | Database name. |
| backend.gpgsql.existingSecret | string | `""` | Existing secret holding the database password. |
| backend.gpgsql.existingSecretPasswordKey | string | `"password"` | Key of the password in `existingSecret`. |
| backend.gpgsql.extraConnectionParameters | string | `"sslmode=prefer"` | Extra libpq connection parameters, e.g. `sslmode=verify-full sslrootcert=/etc/ssl/db/ca.crt`. |
| backend.gpgsql.host | string | `""` | PostgreSQL host. |
| backend.gpgsql.password | string | `""` | Database password (ignored when `existingSecret` is set). |
| backend.gpgsql.port | int | `5432` | PostgreSQL port. |
| backend.gpgsql.user | string | `"pdns"` | Database user. |
| backend.gsqlite3.database | string | `"/var/lib/powerdns/pdns.sqlite3"` | Path of the SQLite database inside the container. |
| backend.schemaInit.enabled | bool | `true` | Run the schema init container. |
| backend.schemaInit.mysqlImage | string | `"docker.io/library/mysql:8.4.11"` | Client image used for gmysql. |
| backend.schemaInit.postgresImage | string | `"docker.io/library/postgres:18.6-alpine"` | Client image used for gpgsql. |
| backend.schemaInit.resources | object | `{}` | Resources of the schema init containers. |
| backend.schemaInit.timeoutSeconds | int | `120` | Seconds to wait for the database to accept connections. |
| backend.type | string | `"gsqlite3"` | Database backend: `gsqlite3` (single replica, PVC), `gpgsql` or `gmysql` (external database, can scale out). |
| commonLabels | object | `{}` | Labels added to every resource. |
| config | object | `{"loglevel":4,"version-string":"anonymous"}` | Extra pdns.conf settings as `setting: value` (see https://doc.powerdns.com/authoritative/settings.html). |
| dns.containerPort | int | `1053` | Port PowerDNS listens on inside the pod. A non privileged port lets the server run without any capability; the Service exposes it on 53. |
| dns.listenAddresses | list | `["0.0.0.0","[::]"]` | Addresses to bind. Drop `[::]` on clusters where pods have IPv6 disabled. |
| extraConfig | string | `""` | Raw lines appended to pdns.conf. |
| extraEnv | list | `[]` | Extra environment variables of the server container. |
| extraVolumeMounts | list | `[]` | Extra volume mounts of the server container. |
| extraVolumes | list | `[]` | Extra volumes. |
| fullnameOverride | string | `""` | Override the full resource names. |
| image.digest | string | `""` | Image digest (`sha256:...`). When set, it takes precedence over the tag. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"docker.io/powerdns/pdns-auth-51"` | Authoritative server image repository. |
| image.tag | string | `""` | Image tag (defaults to the chart appVersion). |
| imagePullSecrets | list | `[]` | Secrets for pulling images from a private registry. |
| livenessProbe | object | `{"failureThreshold":4,"periodSeconds":15,"tcpSocket":{"port":"dns-tcp"},"timeoutSeconds":3}` | Liveness probe. |
| metrics.serviceMonitor.enabled | bool | `false` | Create a Prometheus Operator ServiceMonitor scraping `/metrics` on the webserver (rendered only when the CRD exists). |
| metrics.serviceMonitor.interval | string | `"30s"` | Scrape interval. |
| metrics.serviceMonitor.labels | object | `{}` | Extra ServiceMonitor labels (e.g. `release: kube-prometheus-stack`). |
| metrics.serviceMonitor.scrapeTimeout | string | `"10s"` | Scrape timeout. |
| nameOverride | string | `""` | Override the chart name. |
| networkPolicy.apiAllowedFrom | list | `[]` | Peers allowed to reach the API/webserver (in addition to the recursor and same-release pods). |
| networkPolicy.enabled | bool | `false` | Create NetworkPolicies: DNS stays open, the API/webserver only accepts the peers below. |
| nodeSelector | object | `{}` | Node selector. |
| persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes. |
| persistence.annotations | object | `{}` | PVC annotations. |
| persistence.enabled | bool | `true` | Persist the SQLite database (gsqlite3 backend only). Without it the database lives in an emptyDir. |
| persistence.existingClaim | string | `""` | Use an existing PVC. |
| persistence.size | string | `"1Gi"` | Volume size. |
| persistence.storageClass | string | `""` | Storage class (empty uses the cluster default). |
| podAnnotations | object | `{}` | Pod annotations. |
| podDisruptionBudget.enabled | bool | `false` | Create a PodDisruptionBudget (useful with 2+ replicas). |
| podDisruptionBudget.maxUnavailable | string | `nil` | Maximum unavailable pods (used instead of minAvailable when set). |
| podDisruptionBudget.minAvailable | int | `1` | Minimum available pods. |
| podLabels | object | `{}` | Pod labels. |
| podSecurityContext | object | `{"fsGroup":953,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":953,"runAsNonRoot":true,"runAsUser":953,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. |
| priorityClassName | string | `""` | Priority class of the pods. |
| readinessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"tcpSocket":{"port":"dns-tcp"},"timeoutSeconds":3}` | Readiness probe. |
| recursor.affinity | object | `{}` | Affinity rules. |
| recursor.allowFrom | list | `["127.0.0.0/8","::1/128","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","fc00::/7"]` | Clients allowed to query the recursor. Never leave a recursor open to the Internet. |
| recursor.authoritativeZones | list | `[]` | Zones the recursor sends to the authoritative server of this release (resolved through its Service IP). |
| recursor.autoscaling.enabled | bool | `false` | Enable the recursor HorizontalPodAutoscaler. |
| recursor.autoscaling.maxReplicas | int | `6` |  |
| recursor.autoscaling.minReplicas | int | `2` |  |
| recursor.autoscaling.targetCPUUtilizationPercentage | int | `75` |  |
| recursor.config | object | `{}` | Extra recursor settings merged into recursor.yml (YAML settings, see https://doc.powerdns.com/recursor/yamlsettings.html). |
| recursor.containerPort | int | `1053` | Port the recursor listens on inside the pod (exposed on 53 by its service). |
| recursor.dnssecValidation | string | `"process"` | DNSSEC validation mode (`off`, `process-no-validate`, `process`, `log-fail`, `validate`). |
| recursor.enabled | bool | `false` | Deploy a PowerDNS Recursor next to the authoritative server. |
| recursor.extraEnv | list | `[]` | Extra environment variables. |
| recursor.extraVolumeMounts | list | `[]` | Extra volume mounts. |
| recursor.extraVolumes | list | `[]` | Extra volumes. |
| recursor.forwardZones | list | `[]` | Other forward zones (`zone` + `forwarders` IP:port list). |
| recursor.forwardZonesRecurse | list | `[]` | Forward everything else to these resolvers instead of recursing from the root (e.g. `["9.9.9.9:53"]`). |
| recursor.image.digest | string | `""` | Image digest (takes precedence over the tag). |
| recursor.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| recursor.image.repository | string | `"docker.io/powerdns/pdns-recursor-54"` | Recursor image repository. |
| recursor.image.tag | string | `"5.4.7"` | Recursor image tag. |
| recursor.listenAddresses | list | `["0.0.0.0","::"]` | Addresses to bind (the port is `recursor.containerPort`). |
| recursor.livenessProbe | object | `{"failureThreshold":4,"periodSeconds":15,"tcpSocket":{"port":"dns-tcp"},"timeoutSeconds":3}` | Liveness probe. |
| recursor.metrics.serviceMonitor.enabled | bool | `false` | Create a ServiceMonitor for the recursor. |
| recursor.metrics.serviceMonitor.interval | string | `"30s"` |  |
| recursor.metrics.serviceMonitor.labels | object | `{}` |  |
| recursor.metrics.serviceMonitor.scrapeTimeout | string | `"10s"` |  |
| recursor.nodeSelector | object | `{}` | Node selector. |
| recursor.podAnnotations | object | `{}` | Pod annotations. |
| recursor.podDisruptionBudget.enabled | bool | `false` | Create a PodDisruptionBudget for the recursor. |
| recursor.podDisruptionBudget.maxUnavailable | string | `nil` |  |
| recursor.podDisruptionBudget.minAvailable | int | `1` |  |
| recursor.podLabels | object | `{}` | Pod labels. |
| recursor.readinessProbe | object | `{"periodSeconds":10,"tcpSocket":{"port":"dns-tcp"},"timeoutSeconds":3}` | Readiness probe. |
| recursor.replicaCount | int | `1` | Recursor replicas. |
| recursor.resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"50m","memory":"128Mi"}}` | Resources. |
| recursor.service.annotations | object | `{}` | Service annotations. |
| recursor.service.clusterIP | string | `""` | Static cluster IP. |
| recursor.service.externalTrafficPolicy | string | `""` | External traffic policy. |
| recursor.service.loadBalancerIP | string | `""` | Load balancer IP. |
| recursor.service.loadBalancerSourceRanges | list | `[]` | Source ranges allowed by the load balancer. |
| recursor.service.port | int | `53` | Recursor DNS port. |
| recursor.service.type | string | `"ClusterIP"` | Recursor service type. |
| recursor.tolerations | list | `[]` | Tolerations. |
| recursor.topologySpreadConstraints | list | `[]` | Topology spread constraints. |
| recursor.webserver.allowFrom | list | `["127.0.0.1/32","::1/128","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","fc00::/7"]` | Networks allowed to reach the recursor webserver. |
| recursor.webserver.enabled | bool | `true` | Enable the recursor webserver (API + `/metrics`). |
| recursor.webserver.port | int | `8082` | Webserver port. |
| replicaCount | int | `1` | Number of authoritative server replicas. Must stay at 1 with the gsqlite3 backend. |
| resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}` | Resource requests and limits. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. |
| service.annotations | object | `{}` | Service annotations (e.g. MetalLB or cloud load balancer settings). |
| service.clusterIP | string | `""` | Static cluster IP (lets other resolvers forward to a stable address). |
| service.externalTrafficPolicy | string | `""` | `Local` preserves client source IPs (needed for allow-axfr-ips / ACLs). |
| service.ipFamilies | list | `[]` | IP families. |
| service.ipFamilyPolicy | string | `""` | IP family policy (`SingleStack`, `PreferDualStack`, `RequireDualStack`). |
| service.loadBalancerIP | string | `""` | Load balancer IP, when supported by the provider. |
| service.loadBalancerSourceRanges | list | `[]` | Source ranges allowed by the load balancer. |
| service.nodePorts.tcp | string | `nil` | NodePort for DNS over TCP. |
| service.nodePorts.udp | string | `nil` | NodePort for DNS over UDP. |
| service.port | int | `53` | DNS port exposed by the service. |
| service.type | string | `"ClusterIP"` | DNS service type. Use `LoadBalancer` to serve DNS outside the cluster. |
| serviceAccount.annotations | object | `{}` | Service account annotations. |
| serviceAccount.automount | bool | `false` | PowerDNS never talks to the Kubernetes API: the token is not mounted. |
| serviceAccount.create | bool | `true` | Create a dedicated service account. |
| serviceAccount.name | string | `""` | Service account name (generated when empty). |
| startupProbe | object | `{"failureThreshold":30,"periodSeconds":5,"tcpSocket":{"port":"dns-tcp"}}` | Startup probe. |
| tests.image | string | `""` | Image used by `helm test` (defaults to the authoritative server image, which ships Python). |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. |
| updateStrategy | object | `{}` | Deployment update strategy. With gsqlite3 and persistence the chart forces `Recreate`. |
| webserver.allowFrom | list | `["127.0.0.1/32","::1/128","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","fc00::/7"]` | Networks allowed to reach the webserver. Narrow it to your pod CIDR; the API also requires the key. |
| webserver.enabled | bool | `true` | Enable the built-in webserver (needed by the API and by the Prometheus `/metrics` endpoint). |
| webserver.port | int | `8081` | Webserver port. |

## License

The chart is released under the MIT license. PowerDNS is licensed under the GPL-2.0.
