# Bind9 Helm Chart

A flexible and production-ready Helm chart for deploying ISC Bind9 DNS server on Kubernetes.

## Overview

This Helm chart provides a complete deployment solution for running ISC Bind9, one of the most widely used DNS servers, on Kubernetes. It supports authoritative DNS, zone management, and includes comprehensive configuration options for production deployments.

## Features

- **Production-Ready DNS Server**: Full-featured ISC Bind9 deployment
- **Zone Management**: Easy configuration of DNS zones through Helm values
- **Persistence Support**: Optional persistent storage for zone files and configuration
- **Security Hardening**: Proper security contexts and capabilities
- **Health Checks**: Built-in liveness and readiness probes
- **Flexible Service Configuration**: Support for ClusterIP, NodePort, and LoadBalancer
- **Auto-scaling**: Optional horizontal pod autoscaling
- **Kubernetes-Native**: Full integration with Kubernetes features

## Installation

### Add the Helm Repository

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
```

### Install the Chart

```bash
helm install my-dns unxwares/bind9 \
  --namespace dns-system \
  --create-namespace
```

## Configuration

### Basic DNS Forwarder Example

```yaml
bind:
  namedConf: |
    options {
      directory "/var/cache/bind";
      listen-on-v6 { any; };
      listen-on { any; };
      forwarders {
        9.9.9.9;
        1.1.1.1;
      };
      allow-recursion { any; };
    };
```

### Authoritative DNS Server with Zones

```yaml
bind:
  namedConf: |
    options {
      directory "/var/cache/bind";
      listen-on { any; };
    };

    zone "example.com" {
      type master;
      file "/etc/bind/zones/example-com";
    };

  zones:
    example-com: |
      $TTL 3600
      @       IN      SOA     ns1.example.com. admin.example.com. (
                              2024020101 ; Serial
                              3600       ; Refresh
                              900        ; Retry
                              604800     ; Expire
                              86400 )    ; Minimum TTL

      @       IN      NS      ns1.example.com.
      @       IN      A       192.168.1.1
      ns1     IN      A       192.168.1.1
      www     IN      A       192.168.1.10
      mail    IN      A       192.168.1.20
      @       IN      MX  10  mail.example.com.
```

### With Persistence

```yaml
persistence:
  enabled: true
  accessMode: ReadWriteOnce
  size: 5Gi
  storageClass: "standard"
```

### With Additional Volumes

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

### NodePort Service for External Access

```yaml
service:
  type: NodePort
  ports:
    dnsTcpNodePort: 30053
    dnsUdpNodePort: 30053
    rndcNodePort: 30054
```

## Configuration Options

### Global Settings

| Parameter             | Description                        | Default |
| --------------------- | ---------------------------------- | ------- |
| `replicaCount`        | Number of replicas                 | `1`     |
| `image.repository`    | Container image repository         | `internetsystemsconsortium/bind9` |
| `image.tag`           | Container image tag                | `9.21`  |
| `image.pullPolicy`    | Image pull policy                  | `IfNotPresent` |
| `imagePullSecrets`    | Image pull secrets                 | `[]`    |
| `nameOverride`        | Override chart name                | `""`    |
| `fullnameOverride`    | Override full chart name           | `""`    |

### Pod Configuration

| Parameter              | Description                    | Default |
| ---------------------- | ------------------------------ | ------- |
| `podAnnotations`       | Pod annotations                | `{}`    |
| `podLabels`            | Pod labels                     | `{}`    |
| `podSecurityContext`   | Pod security context           | See `values.yaml` |
| `securityContext`      | Bind9 container security context | See `values.yaml` |

### Service Account

| Parameter                        | Description                      | Default |
| -------------------------------- | -------------------------------- | ------- |
| `serviceAccount.create`          | Create service account           | `true`  |
| `serviceAccount.automount`       | Auto-mount API credentials       | `true`  |
| `serviceAccount.annotations`     | Service account annotations      | `{}`    |
| `serviceAccount.name`            | Service account name             | `""`    |

### Service Configuration

| Parameter                   | Description                  | Default     |
| --------------------------- | ---------------------------- | ----------- |
| `service.enabled`           | Enable service creation      | `true`      |
| `service.annotations`       | Service annotations          | `{}`        |
| `service.type`              | Service type                 | `ClusterIP` |
| `service.ports.dnsTcp`      | DNS TCP port                 | `53`        |
| `service.ports.dnsUdp`      | DNS UDP port                 | `53`        |
| `service.ports.rndc`        | RNDC control port            | `953`       |
| `service.ports.metrics`     | Metrics port                 | `9119`      |
| `service.ports.dnsTcpNodePort` | NodePort for DNS TCP      | `null`      |
| `service.ports.dnsUdpNodePort` | NodePort for DNS UDP      | `null`      |
| `service.ports.rndcNodePort`   | NodePort for RNDC         | `null`      |

### Metrics

| Parameter                               | Description                    | Default |
| --------------------------------------- | ------------------------------ | ------- |
| `metrics.enabled`                       | Enable Bind exporter sidecar   | `false` |
| `metrics.statsGroups`                   | Statistics groups to collect   | `[server,tasks,view]` |
| `metrics.image.repository`              | Exporter image repository      | `prometheuscommunity/bind-exporter` |
| `metrics.image.tag`                     | Exporter image tag             | `v0.8.0` |
| `metrics.image.pullPolicy`              | Exporter image pull policy     | `IfNotPresent` |
| `metrics.securityContext`               | Exporter security context      | See `values.yaml` |
| `metrics.livenessProbe`                 | Exporter liveness probe        | See `values.yaml` |
| `metrics.readinessProbe`                | Exporter readiness probe       | See `values.yaml` |
| `metrics.resources`                     | Exporter resource requests and limits | `{}` |
| `metrics.serviceMonitor.enabled`        | Enable ServiceMonitor          | `true` |
| `metrics.serviceMonitor.endpoints`      | ServiceMonitor endpoints       | See `values.yaml` |

### Bind9 Configuration

| Parameter          | Description                          | Default |
| ------------------ | ------------------------------------ | ------- |
| `bind.args`        | Additional arguments for named       | `[]`    |
| `bind.namedConf`   | Content of named.conf file           | `""`    |
| `bind.zones`       | DNS zone files (key-value pairs)     | `{}`    |

### Persistence

| Parameter                      | Description                   | Default           |
| ------------------------------ | ----------------------------- | ----------------- |
| `persistence.enabled`          | Enable persistence            | `false`           |
| `persistence.accessMode`       | Access mode                   | `ReadWriteOnce`   |
| `persistence.size`             | Persistent volume size        | `1Gi`             |
| `persistence.storageClass`     | Storage class                 | `""`              |
| `persistence.emptyDirSizeLimit`| EmptyDir size limit           | `""`              |

### Volumes and Storage

| Parameter       | Description                              | Default |
| --------------- | ---------------------------------------- | ------- |
| `volumes`       | Additional volumes on the pod            | `[]`    |
| `volumeMounts`  | Additional mounts on the Bind9 container | `[]`    |

### Resources

| Parameter                  | Description              | Default |
| -------------------------- | ------------------------ | ------- |
| `resources.limits.cpu`     | CPU limit                | `""`    |
| `resources.limits.memory`  | Memory limit             | `""`    |
| `resources.requests.cpu`   | CPU request              | `""`    |
| `resources.requests.memory`| Memory request           | `""`    |

### Health Probes

| Parameter                             | Description                     | Default    |
| ------------------------------------- | ------------------------------- | ---------- |
| `livenessProbe.initialDelaySeconds`   | Liveness probe initial delay    | `10`       |
| `livenessProbe.periodSeconds`         | Liveness probe period           | `10`       |
| `readinessProbe.initialDelaySeconds`  | Readiness probe initial delay   | `10`       |
| `readinessProbe.periodSeconds`        | Readiness probe period          | `10`       |

### Autoscaling

| Parameter                                   | Description                        | Default |
| ------------------------------------------- | ---------------------------------- | ------- |
| `autoscaling.enabled`                       | Enable autoscaling                 | `false` |
| `autoscaling.minReplicas`                   | Minimum replicas                   | `1`     |
| `autoscaling.maxReplicas`                   | Maximum replicas                   | `100`   |
| `autoscaling.targetCPUUtilizationPercentage`| Target CPU utilization            | `80`    |

### Node Scheduling

| Parameter       | Description         | Default |
| --------------- | ------------------- | ------- |
| `nodeSelector`  | Node selector       | `{}`    |
| `tolerations`   | Pod tolerations     | `[]`    |
| `affinity`      | Pod affinity        | `{}`    |

## Examples

### Internal DNS Server for Kubernetes Cluster

```yaml
replicaCount: 2

service:
  type: ClusterIP

bind:
  namedConf: |
    options {
      directory "/var/cache/bind";
      listen-on { any; };
      allow-recursion { 10.0.0.0/8; };
      forwarders {
        8.8.8.8;
        8.8.4.4;
      };
    };

    zone "cluster.local" {
      type master;
      file "/etc/bind/zones/cluster-local";
    };

  zones:
    cluster-local: |
      $TTL 300
      @       IN      SOA     ns1.cluster.local. admin.cluster.local. (
                              2024020101
                              3600
                              900
                              604800
                              300 )

      @       IN      NS      ns1.cluster.local.
      ns1     IN      A       10.0.1.10

persistence:
  enabled: true
  size: 2Gi

resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 100m
    memory: 128Mi
```

### Public Authoritative DNS Server

```yaml
replicaCount: 3

service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb

bind:
  namedConf: |
    options {
      directory "/var/cache/bind";
      listen-on { any; };
      recursion no;
    };

    zone "example.com" {
      type master;
      file "/etc/bind/zones/example-com";
    };

  zones:
    example-com: |
      $TTL 3600
      @       IN      SOA     ns1.example.com. admin.example.com. (
                              2024020101
                              3600
                              900
                              604800
                              86400 )

      @       IN      NS      ns1.example.com.
      @       IN      NS      ns2.example.com.
      ns1     IN      A       198.51.100.10
      ns2     IN      A       198.51.100.11
      @       IN      A       198.51.100.20
      www     IN      A       198.51.100.20

persistence:
  enabled: true
  size: 10Gi
  storageClass: fast-ssd

affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchExpressions:
        - key: app.kubernetes.io/name
          operator: In
          values:
          - bind9
      topologyKey: kubernetes.io/hostname
```

## Troubleshooting

### Check Pod Status

```bash
kubectl get pods -n dns-system
kubectl logs -n dns-system <pod-name>
```

### Test DNS Resolution

```bash
# From within the cluster
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup example.com <service-ip>

# From host (if using NodePort)
dig @<node-ip> -p 30053 example.com
```

### Verify Configuration

```bash
# View rendered configuration
helm template my-dns unxwares/bind9 -f values.yaml

# Check named configuration
kubectl exec -n dns-system <pod-name> -- named-checkconf /etc/bind/named.conf

# Check zone files
kubectl exec -n dns-system <pod-name> -- named-checkzone example.com /etc/bind/zones/example-com
```

### Common Issues

1. **DNS Not Resolving**: Check that the service is properly exposed and DNS ports (53 TCP/UDP) are accessible
2. **Zone File Errors**: Validate zone file syntax using `named-checkzone` before deploying
3. **Permission Denied**: Ensure security contexts and capabilities are properly configured
4. **Out of Memory**: Adjust resource limits based on zone sizes and query load

## Security Considerations

- The chart runs Bind9 with minimal required capabilities (`NET_BIND_SERVICE`)
- Consider enabling DNSSEC for zones requiring additional security
- Use network policies to restrict access to DNS services
- Regularly update to latest Bind9 versions for security patches
- Never expose recursive DNS servers to the public internet

## License

This project is licensed under the MIT License. See the [LICENSE.md](LICENSE.md) file for details.

## Maintainers

**Maintainer:**
- David Gheghea - david.gheghea@unxwares.com

**Co-Maintainer:**
- Baptiste Gosselin - baptiste.gosselin@unxwares.com

## Links

- [ISC Bind9 Official Website](https://www.isc.org/bind/)
- [Bind9 Documentation](https://bind9.readthedocs.io/)
- [GitHub Repository](https://github.com/UnxWares/helm)
- [Docker Hub](https://hub.docker.com/r/internetsystemsconsortium/bind9)

---

## Contributing

We welcome contributions! Please see our [CONTRIBUTING.md](../../CONTRIBUTING.md) for guidelines.

### Reporting Issues

For bugs or feature requests, please open an issue on our [GitHub repository](https://github.com/UnxWares/helm/issues).

### Security Vulnerabilities

If you discover a security vulnerability, please email: **security@unxwares.com**

### Questions and Support

For general questions: **opensource@unxwares.com**

---

**Made with ❤️ by the UnxWares Team**
