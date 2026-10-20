# Bind9 Helm Chart

![Version: 2026.10.1](https://img.shields.io/badge/Version-2026.10.1-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 9.20](https://img.shields.io/badge/AppVersion-9.20-informational?style=flat-square)

A flexible and production-ready Helm chart for running the [ISC BIND 9](https://www.isc.org/bind/) DNS server on Kubernetes,
with the official `internetsystemsconsortium/bind9` image.

## Features

- Authoritative or recursive DNS, configured with your own `named.conf` and zone files
- **Hardened**: named binds port 53 then runs as the `bind` user (uid 53) with only `NET_BIND_SERVICE`; read-only root filesystem, seccomp `RuntimeDefault`, no service account token
- Optional persistence for `/var/lib/bind` (dynamic zones, journals, DNSSEC keys)
- Prometheus metrics through the `bind_exporter` sidecar and an optional ServiceMonitor
- NodePort / LoadBalancer exposure, PodDisruptionBudget, NetworkPolicy, topology spread, HPA
- `helm test` checks that the server answers over UDP and TCP

## Installation

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
helm install my-dns unxwares/bind9 --namespace dns-system --create-namespace
```

Charts are signed: see [verifying signatures](https://github.com/UnxWares/helm/blob/main/SECURITY.md#verifying-chart-signatures).

## Configuration examples

Zone files from `bind.zones` are mounted as `/etc/bind/<key>.zone`. Keep `directory "/var/cache/bind";` in the options:
it is the only writable working directory.

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

Never open recursion to the Internet.

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

### With persistence (dynamic zones, DNSSEC keys)

```yaml
persistence:
  enabled: true
  accessMode: ReadWriteOnce
  size: 5Gi
  storageClass: "standard"
```

### With additional volumes

```yaml
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

### NodePort service for external access

```yaml
service:
  type: NodePort
  ports:
    dnsTcpNodePort: 30053
    dnsUdpNodePort: 30053
```

### Metrics

```yaml
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
    labels:
      release: kube-prometheus-stack
```

## Upgrading

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
```

- **`the working directory is not writable`**: add `directory "/var/cache/bind";` to `options`.
- **`permission denied` on files under /var/lib/bind**: the files must be readable/writable by uid or gid 53.

## Requirements

Kubernetes: `>=1.27.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity rules. |
| autoscaling.enabled | bool | `false` | Enable the HorizontalPodAutoscaler (static zones only: no persistence). |
| autoscaling.maxReplicas | int | `10` |  |
| autoscaling.minReplicas | int | `1` |  |
| autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
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
| metrics.image.tag | string | `"v0.8.0"` | Exporter image tag. |
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

## Credits

See [CREDITS.md](CREDITS.md). Thanks to Pierre Gindraud ([@Turgon37](https://github.com/Turgon37)) and
Kostiantyn Astakhov ([@kastakhov](https://github.com/kastakhov)) for their contributions.

## License

The chart is released under the MIT license. BIND 9 is licensed under the MPL-2.0.
