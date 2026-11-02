# Bind9 Helm Chart

![Version: 2026.11.1](https://img.shields.io/badge/Version-2026.11.1-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 9.20](https://img.shields.io/badge/AppVersion-9.20-informational?style=flat-square)

[ISC BIND 9](https://www.isc.org/bind/) is the reference implementation of the DNS protocol: it serves as an
authoritative server, a recursive resolver or both. This chart runs `named` from the official
`internetsystemsconsortium/bind9` image as a Deployment, configured with your own `named.conf` and zone files, with
an optional Prometheus exporter. The chart is maintained by UnxWares.

## Features

- Authoritative or recursive DNS, configured with your own `named.conf` (`bind.namedConf`) and zone files
  (`bind.zones`). The default configuration is authoritative only: no recursion, no zone transfers, version hidden.
- Hardened: named binds port 53 as root with only `NET_BIND_SERVICE`, `SETUID` and `SETGID`, then runs as the `bind`
  user (uid 53). Read-only root filesystem, seccomp `RuntimeDefault`, no service account token.
- Pods restart on their own when `named.conf` or a zone file changes (checksum annotation).
- Optional persistence for `/var/lib/bind` (dynamic zones, journals, secondary zones, DNSSEC keys).
- Prometheus metrics through a `bind_exporter` sidecar and an optional ServiceMonitor.
- ClusterIP, NodePort or LoadBalancer Service; the rndc control port stays off the Service unless you ask for it.
- PodDisruptionBudget, NetworkPolicy, topology spread constraints and HorizontalPodAutoscaler.
- `helm test` checks that the server answers over UDP and TCP.

## Architecture

With a release named `my-dns`, the resources are called `my-dns-bind9` (or just the release name when it already
contains `bind9`). This is `<fullname>` below.

| Resource | Name | Created when | Content |
|----------|------|--------------|---------|
| Deployment | `<fullname>` | always | container `bind9` (named), plus container `bind9-exporter` with `metrics.enabled`; no init container |
| ConfigMap | `<fullname>-config` | always | `named.conf` (`bind.namedConf`, preceded by a `statistics-channels` block with `metrics.enabled`) and one `<key>.zone` per entry of `bind.zones` |
| Service | `<fullname>` | `service.enabled` (default) | `dns-tcp` and `dns-udp` on 53, `rndc` on 953 with `service.exposeRndc`, `metrics` on 9119 with `metrics.enabled` |
| PersistentVolumeClaim | `<fullname>-pvc` | `persistence.enabled` without `persistence.existingClaim` | `/var/lib/bind`, annotated `helm.sh/resource-policy: keep` |
| ServiceAccount | `<fullname>` | `serviceAccount.create` (default) | token not mounted |
| HorizontalPodAutoscaler | `<fullname>` | `autoscaling.enabled` | CPU target `autoscaling.targetCPUUtilizationPercentage` |
| PodDisruptionBudget | `<fullname>` | `podDisruptionBudget.enabled` | `minAvailable`, or `maxUnavailable` when set |
| NetworkPolicy | `<fullname>` | `networkPolicy.enabled` | ingress: DNS open, rndc and metrics from `networkPolicy.adminAllowedFrom` only |
| ServiceMonitor | `<fullname>` | `metrics.enabled`, `metrics.serviceMonitor.enabled`, the Service, and the `monitoring.coreos.com/v1` CRD | scrapes the `metrics` port |
| Pod (`helm test`) | `<fullname>-test-dns` | `service.enabled` | see [Testing](#testing) |

The chart creates no Secret. Volumes of the `bind9` container:

| Mount | Volume | Purpose |
|-------|--------|---------|
| `/etc/bind/named.conf`, `/etc/bind/<key>.zone` | the ConfigMap (read-only) | configuration and static zones |
| `/var/lib/bind` | the PVC with `persistence.enabled`, otherwise an emptyDir (`persistence.emptyDirSizeLimit`) | files named writes: dynamic zones, journals, secondary zones, keys |
| `/var/cache/bind` | emptyDir, 64Mi | named's working directory (`directory` option): managed keys, dumps |
| `/run/named` | emptyDir, 1Mi | pid file |
| `/tmp` | emptyDir, 16Mi | temporary files |

The exporter reads named's statistics channel on `127.0.0.1:8053` inside the pod and serves Prometheus metrics on
`service.ports.metrics` (9119).

## Images

| Container | Default image | Values |
|-----------|---------------|--------|
| `bind9` (and the `helm test` pod) | `docker.io/internetsystemsconsortium/bind9:9.20` (the tag defaults to the chart `appVersion`) | `image.repository`, `image.tag`, `image.digest` |
| `bind9-exporter` (`metrics.enabled`) | `docker.io/prometheuscommunity/bind-exporter:master@sha256:a1f46e6abf8d284a158a1ba0e3275bc2e17f9119ec227f18bdb20019d24b3bcf` | `metrics.image.repository`, `metrics.image.tag`, `metrics.image.digest` |

This chart has no `imageProvider` setting and there is no UnxWares build of these images: it uses the official ISC
image and the Prometheus community exporter.

- ISC publishes one tag per maintained branch (`9.18`, `9.20`, `9.21`) and moves it to each new patch release.
  `9.20` is the current stable branch, `9.21` the development branch.
- The exporter default is the `master` build of 2026-10-14, pinned by digest: `v0.8.0`, its latest release, was built
  with an old Go toolchain. Set `metrics.image.tag: v0.8.0` to use the release.
- The ISC image is published for `linux/amd64` only (see [Requirements](#requirements)); the exporter image is
  multi-architecture.

To pin an image, set its `digest`: it takes precedence over the tag. Read the current digest of a tag with:

```bash
docker buildx imagetools inspect docker.io/internetsystemsconsortium/bind9:9.20   # prints "Digest: sha256:..."
```

```yaml
image:
  digest: sha256:66092edb53c081fa11b1fa8219e99065b0f497cb38f568ba789702a4c10e2590   # 9.20 on 2026-10-21
```

Known vulnerabilities of the images the charts of this repository can deploy are tracked in the
[CVE watch issue](https://github.com/UnxWares/helm/issues?q=is%3Aissue+is%3Aopen+label%3Acve-watch).

## Requirements

Kubernetes: `>=1.27.0-0`

- **Node architecture**: `linux/amd64`. The ISC image has no arm64 build: on a mixed cluster, set
  `nodeSelector: {kubernetes.io/arch: amd64}` (see [Scheduling](#scheduling)).
- **Storage**: only with `persistence.enabled`: a default StorageClass, `persistence.storageClass`, or an existing
  PVC (`persistence.existingClaim`). `ReadWriteOnce` is enough for a single replica.
- **Exposure outside the cluster**: DNS is UDP and TCP, not HTTP, so there is no Ingress or Gateway API route. Use a
  `LoadBalancer` Service (MetalLB, cloud load balancer) that supports UDP and a Service mixing UDP and TCP on the same
  port, or a `NodePort` Service.
- **Optional**: the Prometheus Operator CRDs for the ServiceMonitor, metrics-server for the HorizontalPodAutoscaler,
  and a CNI that enforces NetworkPolicies for `networkPolicy.enabled`.

## Installation

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
helm install my-dns unxwares/bind9 --namespace dns-system --create-namespace -f my-values.yaml
```

Charts are signed with the UnxWares Helm Charts OpenPGP key (fingerprint
`7902 E52E A435 EF27 C643  2E53 78D6 B532 C599 DA9B`, public key https://helm.unxwares.studio/pgp-public-key.asc).
To verify the package before installing it:

```bash
curl -fsSL https://helm.unxwares.studio/pgp-public-key.asc | gpg --import
gpg --export 7902E52EA435EF27C6432E5378D6B532C599DA9B > ~/.gnupg/unxwares-helm.gpg
helm install my-dns unxwares/bind9 --namespace dns-system --create-namespace -f my-values.yaml \
  --verify --keyring ~/.gnupg/unxwares-helm.gpg
```

See also [verifying signatures](https://github.com/UnxWares/helm/blob/main/SECURITY.md#verifying-chart-signatures).

Without values, named starts with no zone and answers REFUSED to every query. A real install needs at least your
zones in `bind.namedConf` and `bind.zones` (see the
[authoritative server example](#authoritative-dns-server-with-zones)) and, to serve clients outside the cluster, a
`NodePort` or `LoadBalancer` Service (see [Exposure](#exposure)).

After the install, query the server from inside the pod, or through a port-forward (TCP only, hence `dig +tcp`):

```bash
kubectl exec -n dns-system deploy/my-dns-bind9 -c bind9 -- dig @127.0.0.1 www.example.com

kubectl port-forward -n dns-system svc/my-dns-bind9 5353:53
dig +tcp -p 5353 @127.0.0.1 www.example.com
```

Pods of the cluster reach it at `my-dns-bind9.dns-system.svc` on port 53.

## Configuration

### named.conf and zone files

`bind.namedConf` is the whole `named.conf`. Each entry of `bind.zones` becomes the file `/etc/bind/<key>.zone` (the
key must be a valid ConfigMap key: letters, digits, `-`, `_` and `.`). Reference it from a `zone` statement:

```yaml
bind:
  namedConf: |
    options {
      directory "/var/cache/bind";
      listen-on { any; };
      listen-on-v6 { any; };
      recursion no;
      allow-transfer { none; };
      version none;
    };
    zone "example.org" {
      type primary;
      file "/etc/bind/example-org.zone";
    };
  zones:
    example-org: |
      $TTL 3600
      @   IN SOA ns1.example.org. hostmaster.example.org. ( 2026110201 3H 15M 1W 1H )
      @   IN NS  ns1.example.org.
      ns1 IN A   192.0.2.1
      www IN A   192.0.2.10
```

- Keep `directory "/var/cache/bind";`: it is the only writable working directory (the root filesystem is read-only).
- Keep `127.0.0.1` in `listen-on` (`any` includes it): the liveness and readiness probes run `dig @127.0.0.1`.
- Files under `/etc/bind` are read-only. Use `bind.zones` for static zones. Zones that named writes (dynamic updates,
  secondary zones, inline signing) need their `file`, journal and keys under `/var/lib/bind`, with persistence
  enabled to keep them across restarts.
- Any change to `named.conf` or a zone restarts the pods (rolling update, or `Recreate` with a `ReadWriteOnce`
  volume). Increase the SOA serial when you change a zone that has secondaries.
- A ConfigMap is limited to 1 MiB: mount large zones from your own ConfigMap or volume
  (see [Extra arguments, volumes and mounts](#extra-arguments-volumes-and-mounts)).
- Logs go to stderr (`named -g`): do not configure `logging` channels that write to files, unless you mount a
  writable volume for them.

### Persistence

Without persistence, `/var/lib/bind` is an emptyDir and its content is lost when the pod is replaced.

```yaml
persistence:
  enabled: true
  size: 5Gi
  storageClass: "standard"   # empty: the cluster default
  # existingClaim: my-bind-data
```

- The chart creates the PVC `<fullname>-pvc`, unless `persistence.existingClaim` is set, and keeps it on uninstall.
- With a `ReadWriteOnce` volume the Deployment uses the `Recreate` strategy: an upgrade stops the old pod before the
  new one starts (a short interruption). Keep `replicaCount: 1`.
- `fsGroup: 53` makes the files of the volume accessible to named.
- Without persistence, `persistence.emptyDirSizeLimit` caps the emptyDir (e.g. `256Mi`).

### Exposure

The Service is `ClusterIP` by default. To serve clients outside the cluster:

```yaml
service:
  type: LoadBalancer
  externalTrafficPolicy: Local       # keep the client source address
  loadBalancerSourceRanges: []       # restrict who reaches the load balancer, when your provider supports it
  annotations: {}                    # e.g. MetalLB or cloud load balancer settings
```

or with fixed node ports:

```yaml
service:
  type: NodePort
  ports:
    dnsTcpNodePort: 30053
    dnsUdpNodePort: 30053
```

- `service.externalTrafficPolicy` and the node ports only apply to `NodePort` and `LoadBalancer` Services;
  `service.loadBalancerIP` and `service.loadBalancerSourceRanges` only to `LoadBalancer`.
- With the default `Cluster` traffic policy, the source address of external clients is replaced by a node address.
  named ACLs (`allow-query`, `allow-recursion`, `allow-transfer`) then see a cluster address: set
  `externalTrafficPolicy: Local` whenever an ACL depends on the client address.
- `service.ports.dnsTcp` and `service.ports.dnsUdp` change the Service ports only; named always listens on 53 in the
  pod.
- The `metrics` port (with `metrics.enabled`) and the `rndc` port (with `service.exposeRndc`) are on the same Service:
  with a `LoadBalancer` or `NodePort` Service they are published too. See [Security](#security).

### rndc and keys from Secrets

The chart does not configure rndc. To use it, add a key and a `controls` statement to `named.conf`. Keep keys (rndc,
TSIG) out of `bind.namedConf`, which is stored in a ConfigMap: put them in a Secret and include the file.

```bash
kubectl exec -n dns-system deploy/my-dns-bind9 -c bind9 -- tsig-keygen -a hmac-sha256 rndc-key > rndc.key
kubectl exec -n dns-system deploy/my-dns-bind9 -c bind9 -- tsig-keygen -a hmac-sha256 transfer-key > transfer.key
kubectl create secret generic bind9-keys -n dns-system --from-file=rndc.key --from-file=transfer.key
```

```yaml
volumes:
  - name: bind-keys
    secret:
      secretName: bind9-keys
      defaultMode: 0440
volumeMounts:
  - name: bind-keys
    mountPath: /etc/bind/keys
    readOnly: true
bind:
  namedConf: |
    include "/etc/bind/keys/rndc.key";
    include "/etc/bind/keys/transfer.key";
    controls {
      inet 127.0.0.1 port 953 allow { 127.0.0.1; } keys { "rndc-key"; };
    };
    options {
      directory "/var/cache/bind";
      listen-on { any; };
      listen-on-v6 { any; };
      recursion no;
      allow-transfer { none; };
      version none;
    };
    zone "example.com" {
      type primary;
      file "/etc/bind/example-com.zone";
      allow-transfer { key "transfer-key"; };
    };
```

With this `controls` statement rndc only works from inside the pod:
`kubectl exec -n dns-system deploy/my-dns-bind9 -c bind9 -- rndc -k /etc/bind/keys/rndc.key status`. To reach it
from elsewhere, listen on `inet *` with an `allow` list, set `service.exposeRndc: true` and restrict the port with
`networkPolicy.adminAllowedFrom`.

### Replicas, autoscaling and disruption budget

```yaml
replicaCount: 2
podDisruptionBudget:
  enabled: true
  minAvailable: 1        # or maxUnavailable: 1
```

- Several replicas are fine for static zones (from `bind.zones`): each pod loads the same files.
- Zones that named writes (dynamic updates, inline signing) need a single writer: keep one replica with persistence,
  and run secondaries in other releases if you need more servers.
- `autoscaling.enabled` creates a HorizontalPodAutoscaler between `autoscaling.minReplicas` and
  `autoscaling.maxReplicas` on `autoscaling.targetCPUUtilizationPercentage`; `replicaCount` is then ignored. Use it
  with static zones only, and with metrics-server.
- A PodDisruptionBudget with `minAvailable: 1` and a single replica blocks node drains: enable it with 2 replicas or
  more.

### Scheduling

```yaml
nodeSelector:
  kubernetes.io/arch: amd64
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: bind9
        app.kubernetes.io/instance: my-dns
priorityClassName: ""
tolerations: []
affinity: {}
```

The chart sets no topology spread constraint by default.

### Resources and probes

Defaults: `bind9` requests 50m CPU and 64Mi memory, limited to 512Mi; the exporter requests 10m and 32Mi, limited to
128Mi. A recursive resolver with a large cache needs more memory: raise `resources.limits.memory` and set
`max-cache-size` in `options`.

The liveness and readiness probes run `dig @127.0.0.1 version.bind txt chaos`, which succeeds as soon as named
answers, whatever the answer. Override `livenessProbe` and `readinessProbe` (or `metrics.livenessProbe` and
`metrics.readinessProbe`) to change them.

### NetworkPolicy

```yaml
networkPolicy:
  enabled: true
  adminAllowedFrom:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: monitoring
```

The policy only covers ingress. DNS (53 UDP and TCP) stays open to everyone: access control is done by named
(`allow-query`, `allow-recursion`, `allow-transfer`). The rndc and metrics ports only accept the peers of
`networkPolicy.adminAllowedFrom`; with an empty list nobody reaches them, Prometheus included. Egress is not
restricted (recursion, forwarding, zone transfers and NOTIFY need it).

### Metrics

```yaml
metrics:
  enabled: true
  statsGroups: [server, view]
  serviceMonitor:
    enabled: true
    labels:
      release: kube-prometheus-stack
    endpoints:
      - port: metrics
        scheme: http
        interval: 30s
```

- `metrics.enabled` adds the `statistics-channels` block (`127.0.0.1` port 8053, local access only) at the top of
  `named.conf`, the `bind9-exporter` sidecar and the `metrics` port of the Service. Do not declare another statistics
  channel on the same address and port in `bind.namedConf`.
- `metrics.statsGroups` selects the statistics groups the exporter collects (`server`, `view`; `tasks` is
  deprecated).
- The ServiceMonitor is only rendered when `metrics.enabled` is true and the `monitoring.coreos.com/v1` CRD exists.
  `metrics.serviceMonitor.endpoints` is used as is (add `interval`, `scrapeTimeout`, relabelings...).
- With `networkPolicy.enabled`, allow your Prometheus in `networkPolicy.adminAllowedFrom`.

### Extra arguments, volumes and mounts

```yaml
bind:
  args:
    - "-4"               # IPv4 only, e.g. when pods have no IPv6
volumes:
  - name: custom-config
    configMap:
      name: custom-config
volumeMounts:
  - name: custom-config
    mountPath: /etc/bind/custom.conf
    subPath: custom.conf
    readOnly: true
```

`bind.args` are appended to `named -u bind -g`. `volumes` are added to the pod and `volumeMounts` to the `bind9`
container: include the mounted files from `bind.namedConf`. The ConfigMap or Secret must exist before the pod starts.

## Examples

### Authoritative DNS server with zones

```yaml
bind:
  namedConf: |
    options {
      directory "/var/cache/bind";
      listen-on { any; };
      listen-on-v6 { any; };
      recursion no;
      allow-transfer { none; };
      version none;
    };

    zone "example.com" {
      type primary;
      file "/etc/bind/example-com.zone";
    };

  zones:
    example-com: |
      $TTL 3600
      @       IN      SOA     ns1.example.com. admin.example.com. (
                              2026102001 ; Serial
                              3600       ; Refresh
                              900        ; Retry
                              604800     ; Expire
                              86400 )    ; Minimum TTL

      @       IN      NS      ns1.example.com.
      @       IN      A       192.0.2.1
      ns1     IN      A       192.0.2.1
      www     IN      A       192.0.2.10
      mail    IN      A       192.0.2.20
      @       IN      MX  10  mail.example.com.
```

### Forwarding resolver for internal clients

```yaml
bind:
  namedConf: |
    options {
      directory "/var/cache/bind";
      listen-on { any; };
      recursion yes;
      allow-recursion { 10.0.0.0/8; 172.16.0.0/12; 192.168.0.0/16; };
      forwarders {
        9.9.9.9;
        149.112.112.112;
      };
      version none;
    };
```

Never open recursion to the Internet. If this resolver is exposed through a `LoadBalancer`, set
`service.externalTrafficPolicy: Local`: otherwise every client appears with a node address, which `allow-recursion`
accepts.

### Public authoritative server behind a load balancer

```yaml
replicaCount: 3
service:
  type: LoadBalancer
  externalTrafficPolicy: Local
podDisruptionBudget:
  enabled: true
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: bind9
```

Combine it with the zones of the first example. Keep `metrics.enabled` off on a public Service, or restrict the load
balancer with `service.loadBalancerSourceRanges`: the metrics port would be published with DNS.

### Secondary server with persistence

```yaml
persistence:
  enabled: true
  size: 1Gi
bind:
  namedConf: |
    options {
      directory "/var/cache/bind";
      listen-on { any; };
      listen-on-v6 { any; };
      recursion no;
      allow-transfer { none; };
      version none;
    };
    zone "example.com" {
      type secondary;
      primaries { 192.0.2.53; };
      file "/var/lib/bind/example.com.db";
    };
```

The zone transferred from the primary is stored in `/var/lib/bind` and survives restarts. The primary must allow
transfers to this server's source address (usually a node address, since traffic leaving the cluster is
masqueraded) or, better, to a TSIG key (see [rndc and keys from Secrets](#rndc-and-keys-from-secrets)).

## Security

What the chart does by default:

- **Users**: named starts as root only to bind port 53, then switches to `bind` (uid 53, `-u bind`). The exporter
  runs as `nobody` (uid 65534, `runAsNonRoot`). The `helm test` pod runs as uid 53.
- **Capabilities**: every capability is dropped except `NET_BIND_SERVICE`, `SETUID` and `SETGID` on the `bind9`
  container (none on the exporter); `allowPrivilegeEscalation: false`, read-only root filesystem, seccomp
  `RuntimeDefault` for the pod.
- **Service account**: a dedicated one, with `automountServiceAccountToken: false` (named never calls the Kubernetes
  API).
- **named defaults**: no recursion, no zone transfers, `version none`. The statistics channel listens on `127.0.0.1`
  and only accepts `127.0.0.1`.
- **Secrets**: the chart creates none. `bind.namedConf` and `bind.zones` are stored in a ConfigMap, readable by
  anyone who can read ConfigMaps in the namespace: mount keys from a Secret instead
  (see [rndc and keys from Secrets](#rndc-and-keys-from-secrets)).
- **NetworkPolicy** (`networkPolicy.enabled`, off by default): DNS open, rndc and metrics restricted to
  `networkPolicy.adminAllowedFrom`.

What is exposed: DNS on 53 (UDP and TCP) to anyone who reaches the Service; the exporter on 9119 with
`metrics.enabled`; rndc on 953 with `service.exposeRndc`. A `ClusterIP` Service keeps them inside the cluster; a
`NodePort` or `LoadBalancer` Service publishes all of them.

Caveats:

- The `bind9` container does not meet the `restricted` Pod Security Standard (it starts as root and adds `SETUID` and
  `SETGID`); it fits `baseline`. named listens on port 53 inside the pod and the chart has no setting for another
  port, so this cannot be hardened further without changing the templates.
- With a `LoadBalancer` or `NodePort` Service and the default `Cluster` traffic policy, named sees node addresses
  instead of client addresses, so address-based ACLs no longer protect anything. Set `externalTrafficPolicy: Local`,
  and never open recursion to the Internet.
- The exporter's metrics and the rndc port share the DNS Service: on a public Service, restrict them with
  `service.loadBalancerSourceRanges` or keep them disabled.
- The ISC image tag moves with each patch release: pin `image.digest` if you need reproducible deployments.

## Testing

On every pull request, the repository CI checks this chart with:

- `helm lint --strict` with Helm 3 and Helm 4, on the default values and on `ci/default-values.yaml`;
- kubeconform (strict) on the manifests rendered from the default values and from `ci/default-values.yaml`, for
  Kubernetes 1.31 and 1.34;
- the generated `README.md` and `values.schema.json`, which must match `README.md.gotmpl` and `values.yaml`;
- `ah lint` (Artifact Hub metadata).

When the pull request changes the chart, `ct lint` (chart-testing, including the version bump check) and `ct install`
also run: the chart is installed on a kind cluster with `ci/default-values.yaml` (one zone, the metrics sidecar and
the NetworkPolicy enabled), its pods must become ready, then `helm test` runs.

The test pod `<fullname>-test-dns` (bind9 image, uid 53, read-only root filesystem) queries the Service for
`version.bind TXT CH`, once over UDP and once over TCP. It passes when named answers both, whatever the response
code; it does not check the content of your zones. There is no end-to-end test yet.

Run the test after an install:

```bash
helm test my-dns -n dns-system --logs
```

## Operations

- **Backup**: zones from `bind.zones` live in your values: keep them in version control. With persistence, the PVC
  holds what named wrote (dynamic zones, journals, keys, secondary copies): back it up with your volume backup tool
  (CSI VolumeSnapshot, Velero...). `kubectl exec` runs as root without `CAP_DAC_OVERRIDE`, so it may not read the
  files that named keeps private to uid 53, such as DNSSEC private keys. Secondary zones need no backup: they are
  transferred again.
- **Restore**: restore the volume, point `persistence.existingClaim` to it, and install or upgrade the release.
- **Scaling**: static zones scale with `replicaCount` or the HorizontalPodAutoscaler. Zones written by named need a
  single replica (see [Replicas](#replicas-autoscaling-and-disruption-budget)).
- **Logs**: named logs to stderr. Add `querylog yes;` to `options` to log every query (verbose).

```bash
kubectl logs -n dns-system deploy/my-dns-bind9 -c bind9
kubectl logs -n dns-system deploy/my-dns-bind9 -c bind9-exporter
kubectl get pods,svc,endpointslices -n dns-system -l app.kubernetes.io/instance=my-dns
kubectl exec -n dns-system deploy/my-dns-bind9 -c bind9 -- cat /etc/bind/named.conf
```

## Upgrading

### To 2026.10.2

- **Exporter image**: `metrics.image.tag` now defaults to the `master` build of bind_exporter of 2026-10-14, pinned
  by digest (the exporter code of `v0.8.0`, built with a current Go toolchain). Set `metrics.image.tag: v0.8.0` to
  keep the release.

### To 2026.10.1

- **Image**: the default tag is now `9.20`, ISC's current stable (ESV) branch. `9.21` is the development branch;
  set `image.tag: "9.21"` to keep it.
- **Privileges**: named now runs as `bind` (uid 53) after binding port 53. Files in an existing `/var/lib/bind` volume
  are made group-accessible through `fsGroup: 53`. If you set custom `podSecurityContext`/`securityContext` values,
  compare them with the new defaults.
- **Working directory**: named runs from `/var/cache/bind` (emptyDir). Make sure your `options` use
  `directory "/var/cache/bind";` and that writable files (journals, keys) live under `/var/lib/bind`.
- **rndc** is no longer exposed by the Service: set `service.exposeRndc: true` if you need it.
- **ServiceMonitor** now requires `metrics.enabled: true` and is skipped when the Prometheus Operator CRD is absent.
  `metrics.serviceMonitor.enabled` now defaults to `false`.

## Troubleshooting

```bash
# Check the configuration and a zone file
kubectl exec -n dns-system deploy/my-dns-bind9 -c bind9 -- named-checkconf /etc/bind/named.conf
kubectl exec -n dns-system deploy/my-dns-bind9 -c bind9 -- named-checkzone example.com /etc/bind/example-com.zone

# Query the server
kubectl exec -n dns-system deploy/my-dns-bind9 -c bind9 -- dig @127.0.0.1 www.example.com

# Events, and the logs of a crashing pod
kubectl describe pod -n dns-system -l app.kubernetes.io/instance=my-dns
kubectl logs -n dns-system deploy/my-dns-bind9 -c bind9 --previous
```

- **`the working directory is not writable`**: add `directory "/var/cache/bind";` to `options`.
- **`permission denied` on files under /var/lib/bind**: the files must be readable/writable by uid or gid 53.
- **`permission denied` or `read-only file system` when named writes a zone or a journal**: the zone file is under
  `/etc/bind`, which is read-only. Move the zones that named writes to `/var/lib/bind`.
- **`exec format error`**: the pod runs on an arm64 node and the ISC image is amd64 only. Set
  `nodeSelector: {kubernetes.io/arch: amd64}`.
- **Probes fail while named runs**: `listen-on` does not include `127.0.0.1`. Use `any` or add `127.0.0.1`.
- **Pod `Pending`**: the PVC is not bound (no default StorageClass: set `persistence.storageClass`), or several
  replicas share a `ReadWriteOnce` volume.
- **The load balancer stays `<pending>`**: your provider may not support UDP, or UDP and TCP in the same Service.
  Check the events with `kubectl describe svc -n dns-system my-dns-bind9`.
- **External clients get REFUSED, or everybody gets recursion**: named sees node addresses. Set
  `service.externalTrafficPolicy: Local`.
- **No metrics**: check `kubectl logs -n dns-system deploy/my-dns-bind9 -c bind9-exporter`, that `named.conf` starts
  with the `statistics-channels` block, and that Prometheus is allowed in `networkPolicy.adminAllowedFrom` when the
  NetworkPolicy is enabled. No ServiceMonitor is created without `metrics.enabled` or without the Prometheus Operator
  CRD.

## Uninstalling

```bash
helm uninstall my-dns -n dns-system
```

Everything is deleted except the PVC `<fullname>-pvc` created with `persistence.enabled`, which carries
`helm.sh/resource-policy: keep`. A claim given through `persistence.existingClaim` and the Secrets you created
yourself (keys) are not managed by the chart and stay too. To delete the data deliberately:

```bash
kubectl delete pvc -n dns-system my-dns-bind9-pvc
```

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity rules. |
| autoscaling.enabled | bool | `false` | Enable the HorizontalPodAutoscaler (static zones only: no persistence). |
| autoscaling.maxReplicas | int | `10` | Maximum number of replicas. |
| autoscaling.minReplicas | int | `1` | Minimum number of replicas. |
| autoscaling.targetCPUUtilizationPercentage | int | `80` | Target average CPU utilization (%). |
| bind.args | list | `[]` | Extra arguments passed to named (after `-u bind -g`). |
| bind.namedConf | string | `"options {\n  directory \"/var/cache/bind\";\n  listen-on { any; };\n  listen-on-v6 { any; };\n  // Authoritative only: no recursion, no zone transfers unless allowed per zone.\n  recursion no;\n  allow-transfer { none; };\n  // Do not reveal the version in CH TXT version.bind queries.\n  version none;\n};\n# zone \"example.com\" {\n#   type primary;\n#   file \"/etc/bind/example-com.zone\";\n# };\n"` | named.conf content. The default is a minimal authoritative-only server: add your zones (see `bind.zones`). Keep `directory "/var/cache/bind";`: it is the only writable working directory. https://bind9.readthedocs.io/en/stable/reference.html |
| bind.zones | object | `{}` | Zone files, mounted as `/etc/bind/<key>.zone`. |
| fullnameOverride | string | `""` | Override the full resource names. |
| image.digest | string | `""` | Image digest (`sha256:...`). When set, it takes precedence over the tag. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"docker.io/internetsystemsconsortium/bind9"` | Bind9 image repository (ISC official image). |
| image.tag | string | `""` | Image tag (defaults to the chart appVersion, the current ISC stable branch). `9.21` is ISC's development branch. |
| imagePullSecrets | list | `[]` | Secrets for pulling images from a private registry. |
| livenessProbe | object | `{"exec":{"command":["dig","+time=2","+tries=1","@127.0.0.1","version.bind","txt","chaos"]},"initialDelaySeconds":10,"periodSeconds":15,"timeoutSeconds":5}` | Liveness probe (dig exits 0 as soon as the server answers, whatever the answer). |
| metrics.enabled | bool | `false` | Run the Prometheus bind_exporter sidecar (reads the statistics channel on 127.0.0.1:8053). |
| metrics.image.digest | string | `""` | Exporter image digest (takes precedence over the tag). |
| metrics.image.pullPolicy | string | `"IfNotPresent"` | Exporter image pull policy. |
| metrics.image.repository | string | `"docker.io/prometheuscommunity/bind-exporter"` | Exporter image repository. |
| metrics.image.tag | string | `"master@sha256:a1f46e6abf8d284a158a1ba0e3275bc2e17f9119ec227f18bdb20019d24b3bcf"` | Exporter image tag. v0.8.0 (November 2024) is the latest release, built with an old Go toolchain (114 known CVEs): the default is the master build of 2026-10-14, the same exporter code rebuilt with a current Go toolchain and dependencies, pinned by digest. |
| metrics.livenessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/","port":"metrics","scheme":"HTTP"},"periodSeconds":10,"successThreshold":1,"timeoutSeconds":1}` | Exporter liveness probe. |
| metrics.readinessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/","port":"metrics","scheme":"HTTP"},"periodSeconds":10,"successThreshold":1,"timeoutSeconds":1}` | Exporter readiness probe. |
| metrics.resources | object | `{"limits":{"memory":"128Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | Exporter resources. |
| metrics.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true,"runAsGroup":65534,"runAsNonRoot":true,"runAsUser":65534}` | Exporter security context (the image runs as `nobody`). |
| metrics.serviceMonitor.enabled | bool | `false` | Create a Prometheus Operator ServiceMonitor (requires `metrics.enabled`; rendered only when the CRD exists). |
| metrics.serviceMonitor.endpoints | list | `[{"port":"metrics","scheme":"http"}]` | ServiceMonitor endpoints. |
| metrics.serviceMonitor.labels | object | `{}` | Extra ServiceMonitor labels (e.g. `release: kube-prometheus-stack`). |
| metrics.statsGroups | list | `["server","view"]` | Statistics groups to collect (`tasks` is deprecated since bind_exporter 0.8.0). |
| nameOverride | string | `""` | Override the chart name. |
| networkPolicy.adminAllowedFrom | list | `[]` | Peers allowed to reach rndc and metrics (e.g. your Prometheus namespace). |
| networkPolicy.enabled | bool | `false` | Create a NetworkPolicy: DNS stays open, rndc and metrics only accept the peers below. |
| nodeSelector | object | `{}` | Node selector. |
| persistence.accessMode | string | `"ReadWriteOnce"` | Access mode. |
| persistence.emptyDirSizeLimit | string | `""` | Size limit of the emptyDir used when persistence is disabled. |
| persistence.enabled | bool | `false` | Persist /var/lib/bind in a PVC. Without it an emptyDir is used. |
| persistence.existingClaim | string | `""` | Use an existing PVC. |
| persistence.size | string | `"1Gi"` | Volume size. |
| persistence.storageClass | string | `""` | Storage class (empty uses the cluster default). |
| podAnnotations | object | `{}` | Pod annotations. |
| podDisruptionBudget.enabled | bool | `false` | Create a PodDisruptionBudget (useful with 2+ replicas). |
| podDisruptionBudget.maxUnavailable | string | `nil` | Maximum unavailable pods (used instead of minAvailable when set). |
| podDisruptionBudget.minAvailable | int | `1` | Minimum available pods. |
| podLabels | object | `{}` | Pod labels. |
| podSecurityContext | object | `{"fsGroup":53,"fsGroupChangePolicy":"OnRootMismatch","seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. named starts as root only to bind port 53, then switches to the `bind` user (uid 53) with `-u bind`. |
| priorityClassName | string | `""` | Priority class of the pods. |
| readinessProbe | object | `{"exec":{"command":["dig","+time=2","+tries=1","@127.0.0.1","version.bind","txt","chaos"]},"initialDelaySeconds":5,"periodSeconds":10,"timeoutSeconds":5}` | Readiness probe. |
| replicaCount | int | `1` | Number of Bind9 replicas. With `persistence.enabled` and a ReadWriteOnce volume, keep 1. |
| resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}` | Bind9 container resources. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"add":["NET_BIND_SERVICE","SETUID","SETGID"],"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Bind9 container security context: every capability is dropped except the three named needs to bind port 53 and switch user. |
| service.annotations | object | `{}` | Service annotations (e.g. MetalLB or cloud load balancer settings). |
| service.enabled | bool | `true` | Create the DNS service. |
| service.exposeRndc | bool | `false` | Expose the rndc control port through the service. Off by default: rndc is an administrative channel. |
| service.externalTrafficPolicy | string | `""` | `Local` preserves client source IPs (needed by ACLs such as allow-transfer). |
| service.loadBalancerIP | string | `""` | Load balancer IP, when supported by the provider. |
| service.loadBalancerSourceRanges | list | `[]` | Source ranges allowed by the load balancer. |
| service.ports.dnsTcp | int | `53` | DNS TCP port. |
| service.ports.dnsTcpNodePort | string | `nil` | NodePort for DNS over TCP. |
| service.ports.dnsUdp | int | `53` | DNS UDP port. |
| service.ports.dnsUdpNodePort | string | `nil` | NodePort for DNS over UDP. |
| service.ports.metrics | int | `9119` | Prometheus exporter port. |
| service.ports.metricsNodePort | string | `nil` | NodePort for the metrics port. |
| service.ports.rndc | int | `953` | rndc port (only exposed with `service.exposeRndc`). |
| service.ports.rndcNodePort | string | `nil` | NodePort for rndc. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | Service account annotations. |
| serviceAccount.automount | bool | `false` | Bind9 never talks to the Kubernetes API: the token is not mounted. |
| serviceAccount.create | bool | `true` | Create a dedicated service account. |
| serviceAccount.name | string | `""` | Service account name (generated when empty). |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. |
| volumeMounts | list | `[]` | Additional volumeMounts on the Bind9 container. |
| volumes | list | `[]` | Additional volumes on the pod. |

## License

The chart is released under the MIT license. BIND 9 is licensed under the MPL-2.0.

## Credits

See [CREDITS.md](CREDITS.md). Thanks to Pierre Gindraud ([@Turgon37](https://github.com/Turgon37)) and
Kostiantyn Astakhov ([@kastakhov](https://github.com/kastakhov)) for their contributions.
