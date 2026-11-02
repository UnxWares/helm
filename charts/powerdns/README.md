# PowerDNS Helm Chart

![Version: 2026.11.5](https://img.shields.io/badge/Version-2026.11.5-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 5.1.5](https://img.shields.io/badge/AppVersion-5.1.5-informational?style=flat-square)
[![UWOSC: maintained](https://helm.unxwares.studio/assets/uwosc/mini-maintained.svg)](https://helm.unxwares.studio/#open-source)

[PowerDNS Authoritative Server](https://doc.powerdns.com/authoritative/) serves DNS zones stored in a database and
manages them through a REST API. This chart deploys it on Kubernetes with a SQLite, PostgreSQL or MySQL/MariaDB
backend and, optionally, a [PowerDNS Recursor](https://doc.powerdns.com/recursor/) that resolves names for your
clients and sends your own zones to the authoritative server. The chart is maintained by UnxWares and runs the
UnxWares builds of PowerDNS by default.

## Features

- **UnxWares images by default**: PowerDNS built from the release tarballs on current Alpine bases, and the database
  clients alone for the schema init, rebuilt twice a week; the official images stay available with
  `imageProvider: upstream` (see [Images](#images)).
- **Authoritative DNS** with DNSSEC, on SQLite (single replica + PVC), PostgreSQL or MySQL/MariaDB (scale out).
- **Automatic schema creation**: the schema shipped in the PowerDNS image is applied when the database is empty
  (idempotent init container).
- **REST API** for [ExternalDNS](https://kubernetes-sigs.github.io/external-dns/), PowerDNS-Admin, cert-manager
  webhooks... The API key is generated and kept across upgrades, or read from your own Secret.
- **Optional Recursor** that forwards your zones to the authoritative server and resolves everything else, with
  DNSSEC validation and negative trust anchors for your internal zones.
- **Hardened by default**: non-root (uid 953), read-only root filesystem, every capability dropped, seccomp
  `RuntimeDefault`, no service account token. DNS listens on an unprivileged port inside the pod and the Service
  exposes it on 53.
- **Secrets never land in ConfigMaps**: they are injected as environment variables and rendered at startup into a
  memory-backed volume.
- **Prometheus** `/metrics` with optional ServiceMonitors, **NetworkPolicy** isolating the API, PodDisruptionBudget,
  HPA (SQL backends), topology spread.

## Architecture

With a release named `dns`, the resources are called `dns-powerdns` (or just the release name when it already
contains `powerdns`). This is `<fullname>` below.

| Resource | Name | Created when | Content |
|----------|------|--------------|---------|
| Deployment | `<fullname>` | always | container `pdns` (authoritative server); init containers below |
| Service | `<fullname>` | always | DNS: `dns-udp` and `dns-tcp` on `service.port` (53), to `dns.containerPort` (1053) in the pod |
| Service | `<fullname>-api` | `webserver.enabled` (default) | `http` on `apiService.port` (8081): REST API and `/metrics` |
| ConfigMap | `<fullname>` | always | `pdns.conf` and `secrets.j2`, the template of the secret settings (no secret in it) |
| Secret | `<fullname>` | the API key or a database password is managed by the chart | `api-key` (generated, or `api.key`), `db-password` (inline `backend.<type>.password`); annotated `helm.sh/resource-policy: keep` when the key is generated |
| PersistentVolumeClaim | `<fullname>` | `gsqlite3` backend, `persistence.enabled` (default), no `persistence.existingClaim` | the SQLite database, annotated `helm.sh/resource-policy: keep` |
| ServiceAccount | `<fullname>` | `serviceAccount.create` (default) | shared by the server and the recursor, token not mounted |
| Deployment, Service, ConfigMap | `<fullname>-recursor` | `recursor.enabled` | container `recursor`; Service with DNS on `recursor.service.port` (53), nothing else; ConfigMap `recursor.j2` (the recursor YAML settings) |
| Service | `<fullname>-recursor-api` | `recursor.enabled` and `recursor.webserver.enabled` (default) | `http` on `recursor.webserver.port` (8082): recursor API and `/metrics`, always `ClusterIP` |
| HorizontalPodAutoscaler | `<fullname>`, `<fullname>-recursor` | `autoscaling.enabled`, `recursor.autoscaling.enabled` | CPU target (and memory target for the server, with `autoscaling.targetMemoryUtilizationPercentage`) |
| PodDisruptionBudget | `<fullname>`, `<fullname>-recursor` | `podDisruptionBudget.enabled`, `recursor.podDisruptionBudget.enabled` | `minAvailable`, or `maxUnavailable` when set |
| NetworkPolicy | `<fullname>`, `<fullname>-recursor` | `networkPolicy.enabled` (the second one with `recursor.enabled`) | ingress: DNS open, `http` restricted |
| ServiceMonitor | `<fullname>`, `<fullname>-recursor` | `metrics.serviceMonitor.enabled`, `recursor.metrics.serviceMonitor.enabled`, the webserver, and the `monitoring.coreos.com/v1` CRD | scrapes `/metrics` |
| Pod (`helm test`) | `<fullname>-test-api` | `api.enabled` and `webserver.enabled` | see [Testing](#testing) |

Init containers of the authoritative server:

| Backend | Init containers | What they do |
|---------|-----------------|--------------|
| `gsqlite3` | `sqlite-init` (PowerDNS image) | creates the SQLite database from the image schema when the file is missing or empty |
| `gpgsql`, `gmysql` with `backend.schemaInit.enabled` (default) | `copy-schema` (PowerDNS image), then `schema-init` (PostgreSQL or MySQL client image) | copies the schema of the server version, waits for the database (`backend.schemaInit.timeoutSeconds`), creates the schema when the `domains` table is missing |

`schema-init` gets the database password only (not the API key), mounts `extraVolumeMounts` like the server (a CA
for `sslrootcert`, for example), and has its own memory-backed `/tmp` (1Mi), where the MySQL client reads its
options file.

Volumes of the `pdns` container: the ConfigMap (`/etc/powerdns/pdns.conf` and
`/etc/powerdns/templates.d/secrets.j2`, read-only); `/etc/powerdns/pdns.d`, a memory-backed emptyDir (1Mi) that holds
`secrets.conf`, rendered at startup; `/run/pdns` (control socket, 1Mi) and `/tmp` (16Mi) emptyDirs; with `gsqlite3`,
the data volume (the PVC, or an emptyDir without persistence) mounted on the directory of
`backend.gsqlite3.database`. The recursor mounts its ConfigMap template, `/etc/powerdns/recursor.d` (where its startup
script writes `recursor.yml`), `/run/pdns-recursor` and `/tmp`, all emptyDirs.

The image startup script renders the Jinja2 templates of `/etc/powerdns/templates.d` listed in `TEMPLATE_FILES`
from environment variables: this is how the API key and the database password reach the configuration without being
stored in a ConfigMap, and how the recursor learns the address of the authoritative Service.

## Images

| Component | `imageProvider: unxwares` (default) | `imageProvider: upstream` |
|-----------|--------------------------------------|---------------------------|
| Authoritative server | `ghcr.io/unxwares/pdns-auth` | `docker.io/powerdns/pdns-auth-51` |
| Recursor (`recursor.enabled`) | `ghcr.io/unxwares/pdns-recursor` | `docker.io/powerdns/pdns-recursor-54` |
| PostgreSQL client of the gpgsql schema init | `ghcr.io/unxwares/postgresql-client:18` | `docker.io/library/postgres:18.6-alpine` |
| MySQL client of the gmysql schema init | `ghcr.io/unxwares/mysql-client:8.4` | `docker.io/library/mysql:8.4.13` |

Tags: the authoritative server follows the chart `appVersion` (`image.tag`), the recursor `recursor.image.tag`
(`5.4.9`, required unless `recursor.image.digest` is set); the client images are whole references
(`backend.schemaInit.postgresImage`, `backend.schemaInit.mysqlImage`). The UnxWares client images hold the client
alone, not a database server: `18` and `8.4` take the latest client of the series at each rebuild. The `helm test` pod
uses the authoritative server image, or `tests.image`.

The UnxWares images are the same PowerDNS versions, built from the release tarballs on current Alpine bases and
rebuilt twice a week (Monday and Thursday), with the backends the chart supports (bind, gsqlite3, gpgsql, gmysql) and
without the tools of the Debian images (vim, curl...). They keep the `pdns` user (uid 953), the paths, the ports and
the startup script that renders `/etc/powerdns/templates.d`, so the chart configures both image sets the same way.
They are built for `linux/amd64` and `linux/arm64`. Sources:
[images/](https://github.com/UnxWares/helm/tree/main/images).

`imageProvider` only fills the values left empty: `image.repository`, `recursor.image.repository`,
`backend.schemaInit.postgresImage` and `backend.schemaInit.mysqlImage` override it for one component.

```yaml
imageProvider: upstream
```

To pin an image: the UnxWares images also have one immutable tag per build (`<version>-<YYYYMMDD>`), and every image
value accepts a digest, which takes precedence over the tag.

```yaml
image:
  tag: "5.1.5-20261102"
recursor:
  image:
    digest: sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef   # your digest
backend:
  schemaInit:
    postgresImage: ghcr.io/unxwares/postgresql-client:18-20261102
```

Every UnxWares tag is signed with cosign (keyless, by the image workflow of the repository). To verify an image:

```bash
cosign verify ghcr.io/unxwares/pdns-auth:5.1.5 \
  --certificate-identity 'https://github.com/UnxWares/helm/.github/workflows/images.yaml@refs/heads/main' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

A default install runs the authoritative server image only. The recursor and the PostgreSQL/MySQL client images of
the schema init are only pulled when enabled; the Artifact Hub security report covers the default image. Known
vulnerabilities of every image the chart can deploy, upstream images included, are tracked in the
[CVE watch issue](https://github.com/UnxWares/helm/issues?q=is%3Aissue+is%3Aopen+label%3Acve-watch).

## Requirements

Kubernetes: `>=1.27.0-0`

- **Kubernetes 1.27 to 1.29**: supported; the preStop hooks (see
  [Shutdown and rolling updates](#shutdown-and-rolling-updates)) run `sleep` from the image there, and use the
  `sleep` lifecycle action from 1.30, where that action is enabled by default.
- **Node architecture**: `linux/amd64` or `linux/arm64` (all default images are multi-architecture).
- **Storage**: the default `gsqlite3` backend asks for a 1Gi `ReadWriteOnce` PVC from the default StorageClass (or
  `persistence.storageClass`, or `persistence.existingClaim`). The SQL backends need no volume.
- **Database** (`gpgsql`, `gmysql`): an existing PostgreSQL or MySQL/MariaDB database and user, reachable from the
  pods. The chart does not deploy one. With `backend.schemaInit.enabled`, the user needs the right to create tables.
- **Exposure outside the cluster**: DNS is UDP and TCP, not HTTP, so there is no Ingress or Gateway API route. Use a
  `LoadBalancer` Service that supports UDP and a Service mixing UDP and TCP on the same port, or a `NodePort` Service.
  The chart creates no Ingress for the API either.
- **IPv6**: the default listen addresses include `[::]` (`::` for the recursor); remove them where pods have no IPv6.
- **Optional**: the Prometheus Operator CRDs for the ServiceMonitors, metrics-server for the
  HorizontalPodAutoscalers, and a CNI that enforces NetworkPolicies for `networkPolicy.enabled`.

## Installation

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
helm install dns unxwares/powerdns --namespace dns --create-namespace
```

Charts are signed with the UnxWares Helm Charts OpenPGP key (fingerprint
`7902 E52E A435 EF27 C643  2E53 78D6 B532 C599 DA9B`, public key https://helm.unxwares.studio/pgp-public-key.asc).
To verify the package before installing it:

```bash
curl -fsSL https://helm.unxwares.studio/pgp-public-key.asc | gpg --import
gpg --export 7902E52EA435EF27C6432E5378D6B532C599DA9B > ~/.gnupg/unxwares-helm.gpg
helm install dns unxwares/powerdns --namespace dns --create-namespace --verify --keyring ~/.gnupg/unxwares-helm.gpg
```

See also [verifying signatures](https://github.com/UnxWares/helm/blob/main/SECURITY.md#verifying-chart-signatures).

The defaults give a working server: SQLite on a PVC, the API enabled with a generated key, DNS on a `ClusterIP`
Service. For a real install, set at least the SOA used for new zones, and choose how DNS is exposed
([DNS service](#dns-service-and-listen-addresses)) and which database to use
([Database backends](#database-backends)):

```yaml
config:
  default-soa-content: ns1.example.com. hostmaster.@ 0 10800 3600 604800 3600
```

After the install, read the API key, create a zone through the API and query it. A port-forward reaches the API from
`127.0.0.1`, which `webserver.allowFrom` accepts; it only carries TCP, hence `dig +tcp`:

```bash
API_KEY=$(kubectl get secret -n dns dns-powerdns -o jsonpath='{.data.api-key}' | base64 -d)
kubectl port-forward -n dns svc/dns-powerdns-api 8081:8081 &

curl -s -H "X-API-Key: $API_KEY" http://127.0.0.1:8081/api/v1/servers/localhost
curl -s -H "X-API-Key: $API_KEY" -X POST http://127.0.0.1:8081/api/v1/servers/localhost/zones \
  -d '{"name": "example.com.", "kind": "Native", "nameservers": ["ns1.example.com."]}'
curl -s -H "X-API-Key: $API_KEY" -X PATCH http://127.0.0.1:8081/api/v1/servers/localhost/zones/example.com. \
  -d '{"rrsets": [{"name": "www.example.com.", "type": "A", "ttl": 300, "changetype": "REPLACE",
       "records": [{"content": "192.0.2.10", "disabled": false}]}]}'

kubectl port-forward -n dns svc/dns-powerdns 5353:53 &
dig +tcp -p 5353 @127.0.0.1 www.example.com
```

Pods of the cluster reach DNS at `dns-powerdns.dns.svc` (port 53) and the API at
`http://dns-powerdns-api.dns.svc:8081/api/v1`.

## Configuration

### Database backends

`backend.type` selects the backend: `gsqlite3` (default), `gpgsql` or `gmysql`. `backend.dnssec` (default `true`)
stores DNSSEC keys and metadata in the database. The chart refuses to render an invalid combination: an unknown type,
`gsqlite3` with more than one replica or the HPA, a SQL backend without `host`, or without `password` or
`existingSecret`.

#### SQLite (default) and persistence

```yaml
backend:
  type: gsqlite3
  gsqlite3:
    database: /var/lib/powerdns/pdns.sqlite3
persistence:
  enabled: true
  size: 1Gi
  storageClass: ""        # empty: the cluster default
  # existingClaim: my-pdns-data
```

- A single replica only. The PVC is mounted on the directory of `backend.gsqlite3.database`, the Deployment uses the
  `Recreate` strategy (an upgrade stops the old pod first) and `updateStrategy` is ignored.
- The `sqlite-init` init container creates the database when the file is missing or empty. It always runs with
  `gsqlite3` (`backend.schemaInit.enabled` does not apply).
- Without `persistence.enabled` the database is an emptyDir: every zone is lost when the pod is replaced.

#### PostgreSQL

```yaml
backend:
  type: gpgsql
  gpgsql:
    host: pdns-db-rw.databases.svc
    port: 5432
    dbname: pdns
    user: pdns
    existingSecret: pdns-db              # created beforehand
    existingSecretPasswordKey: password
    extraConnectionParameters: "sslmode=require"
```

- `extraConnectionParameters` are libpq parameters, used by the server (`gpgsql-extra-connection-parameters`) and by
  the schema init. The default, `sslmode=prefer`, encrypts when the server offers TLS but checks no certificate.
- To verify the server certificate against a private CA, mount the CA with `extraVolumes` and `extraVolumeMounts`:
  the `pdns` container and the `schema-init` container both mount them.

```yaml
backend:
  type: gpgsql
  gpgsql:
    host: pdns-db-rw.databases.svc
    existingSecret: pdns-db
    extraConnectionParameters: "sslmode=verify-full sslrootcert=/etc/ssl/db/ca.crt"
extraVolumes:
  - name: db-ca
    secret:
      secretName: pdns-db-ca
extraVolumeMounts:
  - name: db-ca
    mountPath: /etc/ssl/db
    readOnly: true
```

The schema to apply is `schema.pgsql.sql` of the same PowerDNS version: it is in the image under
`/usr/local/share/doc/pdns/`, and in the PowerDNS sources under `modules/gpgsqlbackend/`.

#### MySQL / MariaDB

```yaml
backend:
  type: gmysql
  gmysql:
    host: mariadb.databases.svc
    port: 3306
    dbname: pdns
    user: pdns
    existingSecret: pdns-db
    existingSecretPasswordKey: password
```

The schema init uses `backend.schemaInit.mysqlImage`, or the MySQL client image of `imageProvider`. It passes the
connection settings to the client in an options file on its memory-backed `/tmp`, with the password quoted and
escaped: quotes, backslashes, `#` and spaces in the password are fine.

TLS: the connection is encrypted when the MySQL server offers TLS, without checking its certificate
(`backend.gmysql.verifyServerCertificate: false`), like the default of the MySQL client: MySQL servers use a
self-signed certificate unless configured otherwise. The MariaDB client library of the UnxWares image (Connector/C
3.4) would otherwise check it and refuse to connect (`TLS/SSL error: self-signed certificate in certificate chain`):
the chart sets `MARIADB_TLS_DISABLE_PEER_VERIFICATION=1` in the `pdns` container. With a server certificate from a
public CA, set `verifyServerCertificate: true` to have it checked against the system CAs (UnxWares image only: the
official image does not check it). The chart has no setting for a private CA with `gmysql`.

#### Schema creation

With a SQL backend and `backend.schemaInit.enabled` (default), the `schema-init` init container waits up to
`backend.schemaInit.timeoutSeconds` (120) for the database, then creates the schema when the `domains` table is
missing. Replicas that start together on an empty database do not fail: one creates the schema, the others wait for
it. It never changes an existing schema: when a PowerDNS upgrade changes the schema, apply the upgrade SQL from the
PowerDNS upgrade notes yourself. Set `backend.schemaInit.enabled: false` when your database team manages the schema,
and `backend.schemaInit.resources` to size the init containers.

### API and webserver

```yaml
webserver:
  enabled: true
  port: 8081
  allowFrom:
    - 127.0.0.1/32
    - 10.42.0.0/16        # your pod CIDR
api:
  enabled: true
  existingSecret: powerdns-api-key
  existingSecretKey: api-key
apiService:
  type: ClusterIP
  port: 8081
```

- **Key**: without `api.key` or `api.existingSecret`, the chart generates a 40-character key, stores it in the Secret
  `<fullname>` (key `api-key`) and reuses it on every upgrade. Read it with
  `kubectl get secret -n dns dns-powerdns -o jsonpath='{.data.api-key}' | base64 -d`.
- **GitOps**: tools that render templates offline (Argo CD...) cannot read the generated key back and would rotate
  it on every sync. Set `api.key` or `api.existingSecret`.
- **Access**: the API needs the `X-API-Key` header; `/metrics` needs no key. The webserver only accepts the networks
  of `webserver.allowFrom` (`webserver-allow-from`), private ranges by default: add your pod CIDR if it uses another
  range (e.g. `100.64.0.0/10`).
- **Service**: `<fullname>-api` serves plain HTTP. Keep it `ClusterIP`; if the API must be reached from outside,
  put an authenticated TLS proxy in front of it.
- `api.enabled` requires `webserver.enabled`. With `webserver.enabled: false` there is no API, no `/metrics`, no API
  Service and no `helm test` pod.

### PowerDNS settings

```yaml
config:
  loglevel: 4
  version-string: anonymous
  default-soa-content: ns1.example.com. hostmaster.@ 0 10800 3600 604800 3600
  primary: "yes"
  allow-axfr-ips: 192.0.2.0/24
extraConfig: |
  # Raw lines appended to pdns.conf
  max-tcp-connections=50
zoneCacheRefreshInterval: 30
```

- `config` entries become `key=value` lines of `pdns.conf`
  ([settings](https://doc.powerdns.com/authoritative/settings.html)), after the settings the chart writes itself
  (`local-address`, `socket-dir`, `include-dir`, `launch`, the backend, the webserver and the API). Use the dedicated
  values for those. Quote `"yes"` and `"no"`: unquoted, YAML turns them into booleans.
- `extraConfig` is appended as is.
- `zoneCacheRefreshInterval` sets `zone-cache-refresh-interval`. Empty: the PowerDNS default (300 s) with one
  replica, 30 s with several replicas or the HPA; `0` disables the zone cache. See the
  [high availability example](#high-availability-postgresql-backend-3-replicas).
- Secret settings (`api-key`, `<backend>-password`) are not in `pdns.conf`: they are in
  `/etc/powerdns/pdns.d/secrets.conf`, rendered at startup.

### DNS service and listen addresses

```yaml
service:
  type: LoadBalancer
  port: 53
  externalTrafficPolicy: Local       # keep client addresses (ACLs, AXFR)
  loadBalancerSourceRanges: []
  annotations: {}                    # e.g. MetalLB or cloud load balancer settings
  clusterIP: ""                      # a fixed address, e.g. for resolvers that forward to this server
  ipFamilyPolicy: ""                 # SingleStack, PreferDualStack, RequireDualStack
  nodePorts:
    udp: null                        # NodePort and LoadBalancer only
    tcp: null
dns:
  containerPort: 1053
  listenAddresses:
    - 0.0.0.0
    - "[::]"
```

- The server listens on `dns.containerPort` (1053) on each address of `dns.listenAddresses`; the Service exposes it
  on `service.port`. Drop `[::]` where pods have no IPv6.
- `service.externalTrafficPolicy` and `service.nodePorts` only apply to `NodePort` and `LoadBalancer`;
  `service.loadBalancerIP` and `service.loadBalancerSourceRanges` only to `LoadBalancer`. `service.ipFamilies` sets
  the IP families.
- With the default `Cluster` traffic policy, external clients reach the server with a node address: ACLs such as
  `allow-axfr-ips` then see a cluster address. Set `externalTrafficPolicy: Local`.

### Recursor

```yaml
recursor:
  enabled: true
  authoritativeZones:
    - example.com
    - 10.in-addr.arpa
  validateAuthoritativeZones: false
  forwardZones:
    - zone: corp.example
      forwarders: ["10.0.0.53:53"]
  forwardZonesRecurse: []            # e.g. ["9.9.9.9:53"]: forward everything else instead of recursing
  dnssecValidation: process
  allowFrom:
    - 10.0.0.0/8
    - 172.16.0.0/12
    - 192.168.0.0/16
```

- `recursor.authoritativeZones` are forwarded to the authoritative Service of this release. Its address is
  `service.clusterIP` when set, otherwise the `<FULLNAME>_SERVICE_HOST` variable that Kubernetes injects into the
  recursor pods when they start: if the authoritative Service is recreated with another address, restart the recursor.
- These zones are added as negative trust anchors unless `recursor.validateAuthoritativeZones` is `true`: an internal
  zone has no chain of trust from the root, and validating it would answer SERVFAIL. Set it to `true` only for zones
  signed and delegated with a DS record from the public root.
- `recursor.forwardZones` (other servers) get no negative trust anchor. For internal zones there, add the anchors in
  `recursor.config` (example below). Write IPv6 forwarders in brackets: `[2001:db8::53]:53`.
- `recursor.dnssecValidation` is the recursor's `dnssec.validation` mode (`off`, `process-no-validate`, `process`,
  `log-fail`, `validate`): see the [Recursor DNSSEC documentation](https://doc.powerdns.com/recursor/dnssec.html).
- `recursor.allowFrom` lists the clients allowed to query. Never leave a recursor open to the Internet; add your pod
  CIDR if it is outside the private ranges.
- The recursor listens on `recursor.containerPort` (1053) on `recursor.listenAddresses`; its Service exposes DNS on
  `recursor.service.port` (53). The webserver (`/metrics`) listens on `recursor.webserver.port` (8082), restricted to
  `recursor.webserver.allowFrom`, behind its own `ClusterIP` Service `<fullname>-recursor-api`: a `LoadBalancer`
  recursor Service does not publish it. The chart sets no recursor API key.
- IPv6: forwarder addresses are `IP:port`, with IPv6 addresses in brackets (`[2001:db8::53]:53`). The chart writes
  the address of the authoritative Service that way when it is IPv6. On an IPv6-only cluster the recursor also needs
  an IPv6 source address for its queries: `recursor.config: {outgoing: {source_address: ["::"]}}` (`["0.0.0.0",
  "::"]` on dual-stack).

`recursor.config` is merged into the generated settings
([YAML settings](https://doc.powerdns.com/recursor/yamlsettings.html)). Maps are merged, but a list replaces the
generated one: to add negative trust anchors, repeat those of `authoritativeZones`.

```yaml
recursor:
  enabled: true
  authoritativeZones: [example.com]
  forwardZones:
    - zone: corp.example
      forwarders: ["10.0.0.53:53"]
  config:
    logging:
      loglevel: 6
    recordcache:
      max_entries: 1000000
    dnssec:
      negative_trustanchors:
        - name: example.com
          reason: served by the PowerDNS authoritative server of this release
        - name: corp.example
          reason: internal zone
```

The settings file is a Jinja2 template rendered at startup: do not put `{{` or `{%` in `recursor.config`.

### Secrets

| Secret value | Where it comes from | Kept across upgrades |
|--------------|---------------------|----------------------|
| API key | generated, `api.key`, or `api.existingSecret` / `api.existingSecretKey` | generated: read back from the Secret `<fullname>` at each upgrade; the Secret is kept on uninstall, so a reinstall of the same release reuses it |
| Database password | `backend.<type>.password` (stored in the Secret `<fullname>`, key `db-password`), or `backend.<type>.existingSecret` / `existingSecretPasswordKey` | yes, from your values or your Secret |

They reach the containers as environment variables (`PDNS_API_KEY`, `PDNS_DB_PASSWORD`) read from the Secret, and
the startup script writes them into `/etc/powerdns/pdns.d/secrets.conf`, on a memory-backed volume. Pods restart
when `api.key` or an inline password changes; after changing a Secret of your own, restart them:
`kubectl rollout restart deploy/dns-powerdns -n dns`.

### Replicas, autoscaling and disruption budgets

```yaml
backend:                            # several replicas need a SQL backend
  type: gpgsql
  gpgsql:
    host: pdns-db-rw.databases.svc
    existingSecret: pdns-db
replicaCount: 3
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0
autoscaling:
  enabled: false                    # replaces replicaCount; SQL backends only
  minReplicas: 2
  maxReplicas: 6
  targetCPUUtilizationPercentage: 75
podDisruptionBudget:
  enabled: true
  minAvailable: 1
recursor:
  replicaCount: 2
  autoscaling:
    enabled: false
  podDisruptionBudget:
    enabled: true
```

The recursor is stateless (each replica has its own cache) and scales on its own. A PodDisruptionBudget with
`minAvailable: 1` and a single replica blocks node drains: enable it with 2 replicas or more.

### Scheduling

By default (`spreadAcrossNodes: true`, `recursor.spreadAcrossNodes: true`) the replicas are spread across nodes,
then zones, with `ScheduleAnyway`: the spread never blocks scheduling. Setting `topologySpreadConstraints` (or
`recursor.topologySpreadConstraints`) replaces it.

```yaml
nodeSelector: {}
tolerations: []
affinity: {}
priorityClassName: ""                # used by the server and the recursor
topologySpreadConstraints: []
recursor:
  nodeSelector: {}
  tolerations: []
  affinity: {}
```

### Resources and probes

Defaults: the server requests 50m CPU and 64Mi memory, limited to 512Mi; the recursor requests 50m and 128Mi, limited
to 1Gi (raise it with a large `recordcache`). The schema init containers have no resources unless
`backend.schemaInit.resources` is set.

The probes open a TCP connection to the DNS port. The startup probe gives the server 150 seconds (30 x 5 s) to start;
the liveness probe then restarts it after 4 failures 15 s apart. Override `livenessProbe`, `readinessProbe`,
`startupProbe`, `recursor.livenessProbe` and `recursor.readinessProbe` to change them.

### Shutdown and rolling updates

```yaml
preStopSleepSeconds: 5             # 0 removes the preStop hook
terminationGracePeriodSeconds: 30  # must be greater than preStopSleepSeconds
recursor:
  preStopSleepSeconds: 5
  terminationGracePeriodSeconds: 30
```

When a pod is deleted (rolling update, drain, scale down), Kubernetes removes it from the Service endpoints and stops
its containers at the same time. Nodes and load balancers take a moment to stop sending it traffic: without a delay,
PowerDNS would already be gone and the queries sent to it meanwhile would be refused. A `preStop` hook keeps the
server (`preStopSleepSeconds`) and the recursor (`recursor.preStopSleepSeconds`) answering for 5 s before they get
SIGTERM.

- On Kubernetes 1.30 and later the hook is the `sleep` lifecycle action. On older clusters, where that action is off
  by default, the chart renders an `exec` hook that runs `sleep` from the image instead (the UnxWares and the official
  images have it; check a custom image does too). The chart picks the form from the Kubernetes version Helm reports:
  with `helm template`, pass `--kube-version`.
- `terminationGracePeriodSeconds` covers the sleep and the stop of PowerDNS after SIGTERM: the chart refuses a value
  that is not greater than the sleep.
- With `gsqlite3` and persistence (`Recreate` strategy), there is no other pod to take over: the delay keeps the old
  pod answering a little longer, but the restart still interrupts DNS. Use a SQL backend and several replicas for
  updates without interruption.

### NetworkPolicy

```yaml
networkPolicy:
  enabled: true
  apiAllowedFrom:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: external-dns
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: monitoring
```

One policy per component, ingress only. DNS stays open to everyone: queries are filtered by PowerDNS
(`recursor.allowFrom` for the recursor). The `http` port (API and `/metrics` of the server, `/metrics` of the
recursor) only accepts pods of this release and the peers of `networkPolicy.apiAllowedFrom`, which applies to both:
add your ExternalDNS, your API clients and your Prometheus. Egress is not restricted (database, recursion).

### Monitoring

```yaml
metrics:
  serviceMonitor:
    enabled: true
    interval: 30s
    scrapeTimeout: 10s
    labels:
      release: kube-prometheus-stack
recursor:
  metrics:
    serviceMonitor:
      enabled: true
      labels:
        release: kube-prometheus-stack
```

The ServiceMonitors scrape `/metrics` on the `http` port of `<fullname>-api` and of `<fullname>-recursor-api` (the
second one only with `recursor.enabled`). They need the webserver (`webserver.enabled`, `recursor.webserver.enabled`)
and are only rendered when the `monitoring.coreos.com/v1` CRD exists. Prometheus must also be allowed by
`webserver.allowFrom` (or `recursor.webserver.allowFrom`) and, with the NetworkPolicy, by
`networkPolicy.apiAllowedFrom`.

### Extra environment, volumes and labels

```yaml
commonLabels:
  team: dns
podLabels: {}
podAnnotations: {}
extraEnv:
  - name: TZ
    value: Europe/Paris
extraVolumes: []
extraVolumeMounts: []
recursor:
  extraEnv: []
  extraVolumes: []
  extraVolumeMounts: []
  podLabels: {}
  podAnnotations: {}
```

`commonLabels` go on every resource and pod. `extraEnv` applies to the `pdns` container only; `extraVolumes` to the
pod, and `extraVolumeMounts` to the `pdns` and `schema-init` containers; the `recursor.*` ones to the recursor.

## Examples

### Expose DNS outside the cluster

```yaml
service:
  type: LoadBalancer
  externalTrafficPolicy: Local   # keep client IPs (ACLs, AXFR)
config:
  default-soa-content: ns1.example.com. hostmaster.@ 0 10800 3600 604800 3600
```

### High availability (PostgreSQL backend, 3 replicas)

The authoritative servers are stateless with `gpgsql` or `gmysql`: every replica reads the same database, so the
deployment is as available as that database (use an HA PostgreSQL or MySQL, e.g. CloudNativePG or OpenEverest).

```yaml
backend:
  type: gpgsql
  gpgsql:
    host: pdns-db-rw.databases.svc
    dbname: pdns
    user: pdns
    existingSecret: pdns-db        # key: password
    extraConnectionParameters: "sslmode=require"
replicaCount: 3                    # or autoscaling.enabled: true
podDisruptionBudget:
  enabled: true
recursor:
  replicaCount: 2
  podDisruptionBudget:
    enabled: true
```

What the chart takes care of:

- replicas are spread across nodes, then zones, by default (`spreadAcrossNodes`, never blocks scheduling);
- replicas starting together on an empty database do not fail on the schema creation (one creates it, the others
  wait);
- the API key is generated once and shared by every replica, so the API answers the same on any of them;
- with several replicas, each server refreshes its list of zones every 30 s instead of 300 s
  (`zoneCacheRefreshInterval`).

What to know:

- a **zone** created through the API is served at once by the replica that received the call, and by the others
  after their next zone cache refresh, plus the packet cache: about a minute with the defaults. Until then they
  answer REFUSED for it. Lower `zoneCacheRefreshInterval`, or set it to `0` to disable the zone cache (one database
  query per uncached question), if new zones must be served everywhere at once;
- **records** changed in an existing zone are seen by every replica after their caches expire: 20 s
  (`cache-ttl`, `query-cache-ttl`), 60 s for a name that did not exist (`negquery-cache-ttl`). Tune them in `config`;
- the `gsqlite3` backend is single-replica only.

### ExternalDNS

ExternalDNS reads the API key from a Secret of its own namespace. Give PowerDNS a key of your own and create the same
Secret in both namespaces:

```bash
KEY=$(openssl rand -hex 32)
kubectl create secret generic powerdns-api-key -n dns --from-literal=api-key="$KEY"
kubectl create secret generic powerdns-api-key -n external-dns --from-literal=api-key="$KEY"
```

```yaml
# PowerDNS values
api:
  existingSecret: powerdns-api-key
networkPolicy:
  enabled: true
  apiAllowedFrom:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: external-dns
```

```yaml
# ExternalDNS values (kubernetes-sigs/external-dns chart)
provider:
  name: pdns
policy: sync                      # required by that chart: create-only, sync or upsert-only
extraArgs:
  - --pdns-server=http://dns-powerdns-api.dns.svc:8081
env:
  - name: EXTERNAL_DNS_PDNS_API_KEY
    valueFrom:
      secretKeyRef:
        name: powerdns-api-key
        key: api-key
```

The ExternalDNS pods must also be in `webserver.allowFrom` (private ranges by default).

### Recursor for the cluster

```yaml
recursor:
  enabled: true
  authoritativeZones:
    - example.com
    - 10.in-addr.arpa
  # forwardZonesRecurse: ["9.9.9.9:53"]   # use an upstream resolver instead of the root servers
```

DNSSEC validation stays on for everything else (`recursor.dnssecValidation`). The `authoritativeZones` are added as
negative trust anchors: an internal zone has no chain of trust from the root, and validating it would answer SERVFAIL.
If these zones are signed and delegated with a DS record from the public root, set
`recursor.validateAuthoritativeZones: true`.

### Managing zones

Zones created through the API are served immediately by the replica that received the call (by the others after
their next zone cache refresh, see above). With `pdnsutil`, ask the server to refresh its zone cache; with several
replicas, the others pick the zone up at their next refresh:

```bash
kubectl exec -n dns deploy/dns-powerdns -c pdns -- \
  sh -c 'pdnsutil zone create example.com ns1.example.com && pdns_control rediscover'
```

## Security

What the chart does by default:

- **Users**: every container (server, init containers, recursor, `helm test`) runs as uid and gid 953
  (`runAsNonRoot`), with `fsGroup: 953` for the volumes.
- **Capabilities**: all dropped, none added; `allowPrivilegeEscalation: false`, read-only root filesystem, seccomp
  `RuntimeDefault`. DNS listens on 1053 inside the pod, so no capability is needed. These settings fit the
  `restricted` Pod Security Standard.
- **Service account**: a dedicated one, shared by the server and the recursor, with
  `automountServiceAccountToken: false` (PowerDNS never calls the Kubernetes API).
- **Secrets**: the API key and the database password stay in Secrets, reach the containers as environment variables,
  and are written at startup into a memory-backed volume, never into a ConfigMap. Each container only gets the ones
  it uses (`schema-init` the database password, `helm test` the API key).
- **PowerDNS defaults**: `version-string=anonymous`; the webserver only accepts private ranges
  (`webserver.allowFrom`); the recursor only answers private ranges (`recursor.allowFrom`).
- **NetworkPolicy** (`networkPolicy.enabled`, off by default): DNS open, the `http` ports restricted to the pods of
  the release and `networkPolicy.apiAllowedFrom`.

What is exposed: DNS on the `<fullname>` Service (53, UDP and TCP); the API and `/metrics` on `<fullname>-api` (8081,
plain HTTP, `ClusterIP`); with the recursor, DNS on `<fullname>-recursor` (53) and its webserver on
`<fullname>-recursor-api` (8082, `ClusterIP`). The API requires the key; `/metrics` and the recursor webserver need
none.

Caveats:

- With a `LoadBalancer` or `NodePort` Service and the default `Cluster` traffic policy, clients reach the pods with a
  node address, which the private ranges of `webserver.allowFrom`, `recursor.allowFrom` and `allow-axfr-ips` accept.
  Set `externalTrafficPolicy: Local` on any Service exposed outside the cluster, and never open the recursor to the
  Internet.
- The API is plain HTTP and the key is a single shared secret with full write access to every zone. Keep the API
  Service internal and give the key only to the tools that need it.
- The API key and the database password are visible to anyone who can `kubectl exec` into the pods (environment).
  An inline `api.key` or database password is also stored in the Helm release.
- The gmysql schema init writes the database password to `/tmp/client.cnf`, on a memory-backed emptyDir that only
  this init container mounts, for the life of the pod.
- `sslmode=prefer` (default) does not authenticate the PostgreSQL server: use `verify-full` with a CA when the
  network between PowerDNS and the database is not trusted. Likewise, `gmysql` encrypts without checking the server
  certificate unless `backend.gmysql.verifyServerCertificate` is `true`.
- With `backend.dnssec`, the DNSSEC private keys are in the database: protect its backups accordingly.

## Testing

On every pull request, the repository CI checks this chart with:

- `helm lint --strict` with Helm 3 and Helm 4, on the default values and on each `ci/*-values.yaml`
  (`default-values.yaml`: UnxWares images; `upstream-values.yaml`: `imageProvider: upstream`; both with the SQLite
  backend, the API, the recursor forwarding `example.test` to the authoritative server, and the NetworkPolicies);
- kubeconform (strict) on the manifests rendered from the default values and from each `ci/*-values.yaml`, for
  Kubernetes 1.31 and 1.34;
- the generated `README.md` and `values.schema.json`, which must match `README.md.gotmpl` and `values.yaml`;
- `ah lint` (Artifact Hub metadata).

When the pull request changes the chart, `ct lint` (chart-testing, including the version bump check) and `ct install`
also run: the chart is installed on a kind cluster once per `ci/*-values.yaml` (so on both image sets), its pods must
become ready, then `helm test` runs.

The test pod `<fullname>-test-api` runs Python from the authoritative server image (or `tests.image`), with the same
security contexts and `imagePullSecrets` as the server. It calls `GET /api/v1/servers/localhost` on the
`<fullname>-api` Service with the API key, and fails on any HTTP error or after 10 seconds without an answer. It does
not send DNS queries and does not test the recursor or a SQL backend; it changes nothing.

The end-to-end test (`.github/workflows/e2e.yaml`, scripts `.github/scripts/powerdns-e2e-env.sh` and
`.github/scripts/powerdns-e2e.sh`) runs on pull requests that touch the chart or its images, on every push to main
and every week. It builds the PowerDNS and database client images of the commit, starts PostgreSQL (with TLS) and
MySQL, and installs three releases in a namespace that enforces the `restricted` Pod Security Standard: SQLite with
the recursor and the NetworkPolicy (`ci/default-values.yaml`), PostgreSQL with `sslmode=verify-full` against a CA
mounted with `extraVolumes`, and MySQL; the database password holds `'`, `"`, `\n` (a backslash and an n), `#`, `;`
and `$`. After `helm test`, for each release:

- the API refuses a request without a key, a wrong key, and a zone sent with a wrong key (which is not created);
- a zone created through the API with its records is read back, and a record is added to it;
- the authoritative server answers these records over UDP and TCP from another pod, with the authoritative flag, and
  NXDOMAIN for an unknown name, again after a restart of the server (the zones are in the database);
- with the recursor, the same records resolve through it;
- the server runs as uid 953 with no capability, and the DNS Services only carry DNS;
- with the NetworkPolicy, a pod of `networkPolicy.apiAllowedFrom` reaches the API, another pod does not.

It does not test DNSSEC, zone transfers, several replicas or the official images (chart-testing installs those).

Run the test after an install:

```bash
helm test dns -n dns --logs
```

Unit tests (`tests/*_test.yaml`, [helm-unittest](https://github.com/helm-unittest/helm-unittest), run by
`.github/workflows/unit.yaml` on pull requests, every push to main and every Tuesday) render the chart without a
cluster and check the messages of the required values, the security contexts of every container with both image
providers, the image selection (provider, repository, tag, digest, database client images), the API key generated
once, reused at upgrade and kept on uninstall, secrets passed through `secretKeyRef` only and to the containers that
use them, `pdns.conf` and the secrets template for each backend, the zone cache refresh, the init containers, the
recursor settings (forward zones, IPv6 addresses, negative trust anchors), Services, ServiceMonitors, NetworkPolicies,
HPAs and PDBs, persistence, the preStop hooks on both sides of Kubernetes 1.30 and their grace period check, the
`helm test` pod, the release notes, and the examples of this README.

## Operations

- **Backup, SQLite**: dump the database through the server container (DNSSEC keys included):

  ```bash
  kubectl exec -n dns deploy/dns-powerdns -c pdns -- sqlite3 /var/lib/powerdns/pdns.sqlite3 .dump > pdns.sql
  ```

  To restore, load the dump into a new file on the same volume, then point the chart to it:

  ```bash
  kubectl exec -i -n dns deploy/dns-powerdns -c pdns -- sqlite3 /var/lib/powerdns/restored.sqlite3 < pdns.sql
  helm upgrade dns unxwares/powerdns -n dns --reuse-values \
    --set backend.gsqlite3.database=/var/lib/powerdns/restored.sqlite3
  ```

- **Backup, PostgreSQL and MySQL**: back up the database with its own tools (`pg_dump`, `mysqldump`, your operator's
  backups); it holds the zones and the DNSSEC keys.
- **Export one zone** (records only, without DNSSEC keys): `GET /api/v1/servers/localhost/zones/example.com./export`
  with the API key.
- **Scaling**: `gsqlite3` is limited to one replica (the chart refuses more). The SQL backends scale with
  `replicaCount` or the HPA; see the [high availability example](#high-availability-postgresql-backend-3-replicas) for
  the propagation delays. The recursor scales on its own.
- **Logs**: `config.loglevel` for the server (4 by default, up to 7), `recursor.config.logging.loglevel` for the
  recursor.

```bash
kubectl logs -n dns deploy/dns-powerdns -c pdns
kubectl logs -n dns deploy/dns-powerdns -c schema-init        # or sqlite-init
kubectl logs -n dns deploy/dns-powerdns-recursor -c recursor
kubectl exec -n dns deploy/dns-powerdns -c pdns -- pdns_control ping
kubectl exec -n dns deploy/dns-powerdns -c pdns -- pdns_control purge 'example.com$'   # flush a zone from the cache
kubectl exec -n dns deploy/dns-powerdns-recursor -c recursor -- \
  rec_control --socket-dir=/run/pdns-recursor wipe-cache 'example.com$'
```

## Upgrading

The schema init only creates a missing schema. When a new PowerDNS version changes the database schema, apply the
upgrade SQL given in the [PowerDNS upgrade notes](https://doc.powerdns.com/authoritative/upgrading.html) before
upgrading the chart.

### To 2026.11.3

- **preStop hooks**: the server and recursor pods keep answering for 5 s after they are asked to stop, so they take
  5 s longer to go away (see [Shutdown and rolling updates](#shutdown-and-rolling-updates)). `preStopSleepSeconds: 0`
  and `recursor.preStopSleepSeconds: 0` restore the previous behavior. `terminationGracePeriodSeconds` and
  `recursor.terminationGracePeriodSeconds` (30, the Kubernetes default) are now set by the chart and must stay greater
  than the sleep.

### To 2026.11.2

- **Recursor webserver**: the `http` port (8082) moved from the `<fullname>-recursor` Service to its own `ClusterIP`
  Service, `<fullname>-recursor-api`. The recursor ServiceMonitor follows; update any other client or scrape
  configuration that used `<fullname>-recursor:8082`.
- **Schema init images**: with `imageProvider: unxwares` (default), the schema init now uses
  `ghcr.io/unxwares/postgresql-client:18` and `ghcr.io/unxwares/mysql-client:8.4` (the clients alone);
  `backend.schemaInit.mysqlImage` defaults to empty. Values you set yourself are kept.
- **Generated API key**: the Secret that holds it is now kept on `helm uninstall` (see [Uninstalling](#uninstalling)).
- **gmysql and TLS**: the UnxWares image could not connect to a MySQL server with a self-signed certificate; the
  chart now disables the certificate check of its MariaDB client library (`backend.gmysql.verifyServerCertificate`,
  default `false`). If your MySQL server has a certificate from a public CA and you relied on the check, set it to
  `true`.

### To 2026.10.5 (UnxWares images)

The default images move to `ghcr.io/unxwares/pdns-auth` and `ghcr.io/unxwares/pdns-recursor` (see [Images](#images)):
same PowerDNS versions, same user, paths and configuration. Nothing to change in your values, unless you set
`image.repository` or `recursor.image.repository` to the official images explicitly. To keep the official images:
`imageProvider: upstream`. The UnxWares authoritative image only has the bind, gsqlite3, gpgsql and gmysql backends:
if you load another backend through extra configuration, keep `imageProvider: upstream`.

The recursor now answers for the `recursor.authoritativeZones` that have no public chain of trust (internal zones),
for which DNSSEC validation answered SERVFAIL: they are added as negative trust anchors
(`recursor.validateAuthoritativeZones: false`).

## Troubleshooting

```bash
kubectl get pods,svc,pvc -n dns -l app.kubernetes.io/instance=dns
kubectl describe pod -n dns -l app.kubernetes.io/instance=dns,app.kubernetes.io/component=authoritative
kubectl logs -n dns deploy/dns-powerdns -c pdns --previous
kubectl get configmap -n dns dns-powerdns -o jsonpath='{.data.pdns\.conf}'
```

- **`helm install` fails with `execution error`**: the chart refused the values (`backend.gpgsql.host is required`,
  `the gsqlite3 backend supports a single replica`, `api.enabled requires webserver.enabled`...). Fix the value named
  in the message.
- **Pod stuck in `Init`**: `kubectl logs ... -c schema-init`. `Timed out waiting for PostgreSQL` (or MySQL): wrong
  host or port, a NetworkPolicy on the database side, wrong credentials, or a TLS setting the init container cannot
  satisfy (`sslrootcert` must be on a volume of `extraVolumeMounts`: see [PostgreSQL](#postgresql)).
- **Pod `Pending`**: the PVC is not bound (no default StorageClass: set `persistence.storageClass`).
- **`CrashLoopBackOff` right after start**: read `kubectl logs ... -c pdns --previous`. An error binding `[::]:1053`
  means the pods have no IPv6: remove `[::]` from `dns.listenAddresses` (and `::` from `recursor.listenAddresses`).
- **API answers 401**: wrong key, or a key rotated by an offline renderer (GitOps): set `api.key` or
  `api.existingSecret`.
- **API connection refused or timed out from another namespace**: the client is missing from
  `networkPolicy.apiAllowedFrom` or its network from `webserver.allowFrom`.
- **REFUSED for a zone that exists**: another replica created it and this one has not refreshed its zone cache yet
  (see the [high availability example](#high-availability-postgresql-backend-3-replicas)); or the zone was created
  with `pdnsutil` without `pdns_control rediscover`.
- **The recursor answers REFUSED**: the client is not in `recursor.allowFrom` (pod CIDR outside the private ranges,
  or a load balancer without `externalTrafficPolicy: Local`).
- **The recursor answers SERVFAIL for an internal zone**: the zone is validated with DNSSEC. Check
  `dig +dnssec @<recursor> <name>` for an Extended DNS Error, list the zone in `recursor.authoritativeZones` with
  `recursor.validateAuthoritativeZones: false`, or add a negative trust anchor for a `forwardZones` entry.
- **The recursor cannot reach the authoritative server after the Service was recreated**: the address is read when
  the recursor pod starts. `kubectl rollout restart deploy/dns-powerdns-recursor -n dns`, or set a fixed
  `service.clusterIP`.
- **`gmysql Connection failed ... TLS/SSL error: self-signed certificate`**: `backend.gmysql.verifyServerCertificate`
  is `true` and the MySQL server certificate is not from a public CA. Set it to `false`.
- **`ImagePullBackOff` on `ghcr.io/unxwares/...`**: the cluster cannot reach GHCR. Mirror the images and set the
  repositories, or use `imageProvider: upstream`.

## Uninstalling

```bash
helm uninstall dns -n dns
```

What stays:

- the PVC `<fullname>` of the SQLite database (`gsqlite3` with `persistence.enabled`), which carries
  `helm.sh/resource-policy: keep`; a claim given through `persistence.existingClaim` is not managed by the chart;
- the Secret `<fullname>` when it holds a generated API key (annotated `helm.sh/resource-policy: keep`): a new install
  of the same release in the same namespace reuses the key, so the API clients keep working;
- your external database and the Secrets you created yourself.

With `api.key` or `api.existingSecret`, the Secret `<fullname>` (if any) is deleted. To delete the SQLite data and
the generated key deliberately:

```bash
kubectl delete pvc -n dns dns-powerdns
kubectl delete secret -n dns dns-powerdns
```

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
| autoscaling.maxReplicas | int | `6` | Maximum number of replicas. |
| autoscaling.minReplicas | int | `2` | Minimum number of replicas. |
| autoscaling.targetCPUUtilizationPercentage | int | `75` | Target average CPU utilization (%). |
| autoscaling.targetMemoryUtilizationPercentage | string | `nil` | Target average memory utilization (%). Empty: no memory target. |
| backend.dnssec | bool | `true` | Store DNSSEC keys and metadata in the database (`<backend>-dnssec=yes`). |
| backend.gmysql.dbname | string | `"pdns"` | Database name. |
| backend.gmysql.existingSecret | string | `""` | Existing secret holding the database password. |
| backend.gmysql.existingSecretPasswordKey | string | `"password"` | Key of the password in `existingSecret`. |
| backend.gmysql.host | string | `""` | MySQL/MariaDB host. |
| backend.gmysql.password | string | `""` | Database password (ignored when `existingSecret` is set). |
| backend.gmysql.port | int | `3306` | MySQL/MariaDB port. |
| backend.gmysql.user | string | `"pdns"` | Database user. |
| backend.gmysql.verifyServerCertificate | bool | `false` | Check the certificate of the MySQL server. `false`: the connection is encrypted when the server offers TLS, without checking the certificate, like the default of the MySQL client (`--ssl-mode=PREFERRED`): MySQL servers use a self-signed certificate unless configured otherwise. `true`: the MariaDB client library of the UnxWares image checks it against the system CAs and fails on a self-signed or private certificate; the official image does not check it either way. |
| backend.gpgsql.dbname | string | `"pdns"` | Database name. |
| backend.gpgsql.existingSecret | string | `""` | Existing secret holding the database password. |
| backend.gpgsql.existingSecretPasswordKey | string | `"password"` | Key of the password in `existingSecret`. |
| backend.gpgsql.extraConnectionParameters | string | `"sslmode=prefer"` | Extra libpq connection parameters, e.g. `sslmode=verify-full sslrootcert=/etc/ssl/db/ca.crt` (mount the CA with `extraVolumes` and `extraVolumeMounts`: the schema init container gets them too). |
| backend.gpgsql.host | string | `""` | PostgreSQL host. |
| backend.gpgsql.password | string | `""` | Database password (ignored when `existingSecret` is set). |
| backend.gpgsql.port | int | `5432` | PostgreSQL port. |
| backend.gpgsql.user | string | `"pdns"` | Database user. |
| backend.gsqlite3.database | string | `"/var/lib/powerdns/pdns.sqlite3"` | Path of the SQLite database inside the container. |
| backend.schemaInit.enabled | bool | `true` | Run the schema init container. |
| backend.schemaInit.mysqlImage | string | `""` | Client image used for gmysql. Empty: `ghcr.io/unxwares/mysql-client:8.4` or `docker.io/library/mysql:8.4.13`, from `imageProvider`. |
| backend.schemaInit.postgresImage | string | `""` | Client image used for gpgsql. Empty: `ghcr.io/unxwares/postgresql-client:18` or `docker.io/library/postgres:18.6-alpine`, from `imageProvider`. |
| backend.schemaInit.resources | object | `{}` | Resources of the schema init containers. |
| backend.schemaInit.timeoutSeconds | int | `120` | Seconds to wait for the database to accept connections. |
| backend.type | string | `"gsqlite3"` | Database backend: `gsqlite3` (single replica, PVC), `gpgsql` or `gmysql` (external database, can scale out). |
| commonLabels | object | `{}` | Labels added to every resource. |
| config | object | `{"loglevel":4,"version-string":"anonymous"}` | Extra pdns.conf settings as `setting: value` (see https://doc.powerdns.com/authoritative/settings.html). |
| dns.containerPort | int | `1053` | Port PowerDNS listens on inside the pod. A non privileged port lets the server run without any capability; the Service exposes it on 53. |
| dns.listenAddresses | list | `["0.0.0.0","[::]"]` | Addresses to bind. Drop `[::]` on clusters where pods have IPv6 disabled. |
| extraConfig | string | `""` | Raw lines appended to pdns.conf. |
| extraEnv | list | `[]` | Extra environment variables of the server container. |
| extraVolumeMounts | list | `[]` | Extra volume mounts of the server container, and of the schema init container (gpgsql, gmysql). |
| extraVolumes | list | `[]` | Extra volumes. |
| fullnameOverride | string | `""` | Override the full resource names. |
| image.digest | string | `""` | Image digest (`sha256:...`). When set, it takes precedence over the tag. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `""` | Authoritative server image repository. Empty: `ghcr.io/unxwares/pdns-auth` or `docker.io/powerdns/pdns-auth-51`, from `imageProvider`. |
| image.tag | string | `""` | Image tag (defaults to the chart appVersion). |
| imageProvider | string | `"unxwares"` | Images used when `image.repository`, `recursor.image.repository`, `backend.schemaInit.postgresImage` or `backend.schemaInit.mysqlImage` are empty. `unxwares`: `ghcr.io/unxwares` images, PowerDNS built from the release tarballs on current Alpine bases and the database clients alone, rebuilt twice a week (https://github.com/UnxWares/helm/tree/main/images). `upstream`: the official `docker.io/powerdns` images (Debian), `docker.io/library/postgres` and `docker.io/library/mysql`. Both run as the same `pdns` user with the same paths and startup script. |
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
| preStopSleepSeconds | int | `5` | Seconds the server keeps answering after its pod is marked for deletion, before it gets SIGTERM (preStop hook). The pod leaves the Service endpoints while it stops: without this delay, queries still routed to it during a rolling update or a drain are refused. 0 removes the hook. The hook uses the `sleep` action on Kubernetes 1.30 and later, and runs `sleep` from the image on older clusters. |
| priorityClassName | string | `""` | Priority class of the pods. |
| readinessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"tcpSocket":{"port":"dns-tcp"},"timeoutSeconds":3}` | Readiness probe. |
| recursor.affinity | object | `{}` | Affinity rules. |
| recursor.allowFrom | list | `["127.0.0.0/8","::1/128","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","fc00::/7"]` | Clients allowed to query the recursor. Never leave a recursor open to the Internet. |
| recursor.authoritativeZones | list | `[]` | Zones the recursor sends to the authoritative server of this release (resolved through its Service IP). |
| recursor.autoscaling.enabled | bool | `false` | Enable the recursor HorizontalPodAutoscaler. |
| recursor.autoscaling.maxReplicas | int | `6` | Maximum number of recursor replicas. |
| recursor.autoscaling.minReplicas | int | `2` | Minimum number of recursor replicas. |
| recursor.autoscaling.targetCPUUtilizationPercentage | int | `75` | Target average CPU utilization (%). |
| recursor.config | object | `{}` | Extra recursor settings merged into recursor.yml (YAML settings, see https://doc.powerdns.com/recursor/yamlsettings.html). |
| recursor.containerPort | int | `1053` | Port the recursor listens on inside the pod (exposed on 53 by its service). |
| recursor.dnssecValidation | string | `"process"` | DNSSEC validation mode (`off`, `process-no-validate`, `process`, `log-fail`, `validate`). |
| recursor.enabled | bool | `false` | Deploy a PowerDNS Recursor next to the authoritative server. |
| recursor.extraEnv | list | `[]` | Extra environment variables. |
| recursor.extraVolumeMounts | list | `[]` | Extra volume mounts. |
| recursor.extraVolumes | list | `[]` | Extra volumes. |
| recursor.forwardZones | list | `[]` | Other forward zones (`zone` + `forwarders` IP:port list, IPv6 addresses in brackets: `[2001:db8::53]:53`). |
| recursor.forwardZonesRecurse | list | `[]` | Forward everything else to these resolvers instead of recursing from the root (e.g. `["9.9.9.9:53"]`). |
| recursor.image.digest | string | `""` | Image digest (takes precedence over the tag). |
| recursor.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| recursor.image.repository | string | `""` | Recursor image repository. Empty: `ghcr.io/unxwares/pdns-recursor` or `docker.io/powerdns/pdns-recursor-54`, from `imageProvider`. |
| recursor.image.tag | string | `"5.4.9"` | Recursor image tag (required unless `digest` is set). |
| recursor.listenAddresses | list | `["0.0.0.0","::"]` | Addresses to bind (the port is `recursor.containerPort`). |
| recursor.livenessProbe | object | `{"failureThreshold":4,"periodSeconds":15,"tcpSocket":{"port":"dns-tcp"},"timeoutSeconds":3}` | Liveness probe. |
| recursor.metrics.serviceMonitor.enabled | bool | `false` | Create a ServiceMonitor for the recursor. |
| recursor.metrics.serviceMonitor.interval | string | `"30s"` | Scrape interval. |
| recursor.metrics.serviceMonitor.labels | object | `{}` | Extra labels of the ServiceMonitor (to match your Prometheus selector). |
| recursor.metrics.serviceMonitor.scrapeTimeout | string | `"10s"` | Scrape timeout. |
| recursor.nodeSelector | object | `{}` | Node selector. |
| recursor.podAnnotations | object | `{}` | Pod annotations. |
| recursor.podDisruptionBudget.enabled | bool | `false` | Create a PodDisruptionBudget for the recursor. |
| recursor.podDisruptionBudget.maxUnavailable | string | `nil` | Maximum unavailable recursor pods (takes precedence over `minAvailable`). |
| recursor.podDisruptionBudget.minAvailable | int | `1` | Minimum available recursor pods (used when `maxUnavailable` is null). |
| recursor.podLabels | object | `{}` | Pod labels. |
| recursor.preStopSleepSeconds | int | `5` | Seconds the recursor keeps answering after its pod is marked for deletion, before it gets SIGTERM (preStop hook), like `preStopSleepSeconds` for the server. 0 removes the hook. |
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
| recursor.spreadAcrossNodes | bool | `true` | When `topologySpreadConstraints` is empty, spread the replicas across nodes, then zones (ScheduleAnyway). |
| recursor.terminationGracePeriodSeconds | int | `30` | Grace period of the recursor pods. Must be greater than `recursor.preStopSleepSeconds`. |
| recursor.tolerations | list | `[]` | Tolerations. |
| recursor.topologySpreadConstraints | list | `[]` | Topology spread constraints. |
| recursor.validateAuthoritativeZones | bool | `false` | Validate the `authoritativeZones` with DNSSEC. Leave it off unless these zones are signed and delegated from the public root with a DS record: otherwise validation answers SERVFAIL for them, so the chart adds them as negative trust anchors. |
| recursor.webserver.allowFrom | list | `["127.0.0.1/32","::1/128","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","fc00::/7"]` | Networks allowed to reach the recursor webserver. |
| recursor.webserver.enabled | bool | `true` | Enable the recursor webserver (API + `/metrics`), on its own ClusterIP Service `<fullname>-recursor-api`. |
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
| spreadAcrossNodes | bool | `true` | When `topologySpreadConstraints` is empty, spread the replicas across nodes, then zones (ScheduleAnyway: never blocks scheduling). |
| startupProbe | object | `{"failureThreshold":30,"periodSeconds":5,"tcpSocket":{"port":"dns-tcp"}}` | Startup probe. |
| terminationGracePeriodSeconds | int | `30` | Grace period of the server pods: the preStop sleep, then the time PowerDNS has to stop after SIGTERM. Must be greater than `preStopSleepSeconds`. |
| tests.image | string | `""` | Image used by `helm test` (defaults to the authoritative server image, which ships Python). |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. |
| updateStrategy | object | `{}` | Deployment update strategy. With gsqlite3 and persistence the chart forces `Recreate`. |
| webserver.allowFrom | list | `["127.0.0.1/32","::1/128","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","fc00::/7"]` | Networks allowed to reach the webserver. Narrow it to your pod CIDR; the API also requires the key. |
| webserver.enabled | bool | `true` | Enable the built-in webserver (needed by the API and by the Prometheus `/metrics` endpoint). |
| webserver.port | int | `8081` | Webserver port. |
| zoneCacheRefreshInterval | int | `nil` | Seconds between refreshes of the list of known zones (`zone-cache-refresh-interval`). Each server only serves a zone created through another server's API after its next refresh (until then it answers REFUSED). Empty: PowerDNS default (300) with one replica, 30 with several replicas or the HPA. 0 disables the cache (a database query per uncached question). |

## License

The chart is released under the MIT license. PowerDNS is licensed under the GPL-2.0.
