# Kener Helm Chart

A Helm chart for deploying Kener, a modern and beautiful status page application.

## Overview

Kener is an open-source status page system that allows you to monitor and display the status of your services in a beautiful and user-friendly interface. This Helm chart provides an easy way to deploy Kener on Kubernetes with database support and flexible configuration options.

## Features

- **Modern Status Page**: Beautiful and responsive status page interface
- **Database Integration**: PostgreSQL database support for persistence
- **Flexible Configuration**: Environment-based configuration with secrets support
- **HTTPRoute Support**: Gateway API integration for modern routing
- **Ingress Support**: Traditional ingress controller support
- **Auto-scaling**: Optional horizontal pod autoscaling
- **Health Checks**: Comprehensive liveness, readiness, and startup probes
- **Custom Volumes**: Support for persistent data and uploads

## Installation

### Add the Helm Repository

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
```

### Install the Chart

```bash
helm install my-status unxwares/kener \
  --namespace monitoring \
  --create-namespace
```

## Configuration

### Basic Configuration

```yaml
kener:
  nodeEnv: production
  origin: https://status.mycompany.com
  key: "your-secure-secret-key-here"

database:
  enabled: true
  url: "postgresql://kener:password@postgres:5432/kener"

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - host: status.mycompany.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: status-tls
      hosts:
        - status.mycompany.com
```

### Using Existing Secrets

```yaml
kener:
  nodeEnv: production
  origin: https://status.mycompany.com
  # Reference secret for the encryption key
  keyFrom:
    secretRef: "kener-secrets"
    secretKey: "encryption-key"

database:
  enabled: true
  # Use existing secret for database URL
  existingSecret: "kener-db-secret"
  secretKeys:
    url: database-url
```

### With Persistent Volumes

```yaml
volumes:
  - name: kener-data
    persistentVolumeClaim:
      claimName: kener-data
  - name: kener-uploads
    persistentVolumeClaim:
      claimName: kener-uploads

volumeMounts:
  - name: kener-data
    mountPath: "/app/database"
    readOnly: false
  - name: kener-uploads
    mountPath: "/app/uploads"
    readOnly: false
```

### Gateway API HTTPRoute

```yaml
httpRoute:
  enabled: true
  annotations:
    route.example.com/type: status
  parentRefs:
    - name: main-gateway
      sectionName: https
      namespace: gateway-system
  hostnames:
    - status.mycompany.com
  rules:
    - matches:
      - path:
          type: PathPrefix
          value: /
```

## Configuration Options

### Global Settings

| Parameter             | Description                    | Default              |
| --------------------- | ------------------------------ | -------------------- |
| `replicaCount`        | Number of replicas             | `1`                  |
| `image.repository`    | Container image repository     | `rajnandan1/kener`   |
| `image.tag`           | Container image tag            | Chart appVersion     |
| `image.pullPolicy`    | Image pull policy              | `IfNotPresent`       |
| `imagePullSecrets`    | Image pull secrets             | `[]`                 |
| `nameOverride`        | Override chart name            | `""`                 |
| `fullnameOverride`    | Override full chart name       | `""`                 |

### Kener Configuration

| Parameter               | Description                        | Default                              |
| ----------------------- | ---------------------------------- | ------------------------------------ |
| `kener.nodeEnv`         | Node environment                   | `production`                         |
| `kener.origin`          | Application origin URL             | `https://status.example.com`         |
| `kener.key`             | Encryption key (if not using secret)| `thesuperprivatekeytonotshare`      |
| `kener.keyFrom.secretRef` | Secret name for encryption key   | `""`                                 |
| `kener.keyFrom.secretKey` | Secret key for encryption key    | `""`                                 |

### Database Configuration

| Parameter                    | Description                       | Default                                    |
| ---------------------------- | --------------------------------- | ------------------------------------------ |
| `database.enabled`           | Enable database                   | `true`                                     |
| `database.url`               | Database connection URL           | `postgresql://user:password@host:port/db`  |
| `database.existingSecret`    | Use existing secret for DB URL    | `""`                                       |
| `database.secretKeys.url`    | Key in secret for database URL    | `database-url`                             |

### Service Account

| Parameter                        | Description                      | Default |
| -------------------------------- | -------------------------------- | ------- |
| `serviceAccount.create`          | Create service account           | `true`  |
| `serviceAccount.automount`       | Auto-mount API credentials       | `true`  |
| `serviceAccount.annotations`     | Service account annotations      | `{}`    |
| `serviceAccount.name`            | Service account name             | `""`    |

### Service Configuration

| Parameter       | Description        | Default     |
| --------------- | ------------------ | ----------- |
| `service.type`  | Service type       | `ClusterIP` |
| `service.port`  | Service port       | `3000`      |

### Ingress Configuration

| Parameter              | Description              | Default                    |
| ---------------------- | ------------------------ | -------------------------- |
| `ingress.enabled`      | Enable ingress           | `false`                    |
| `ingress.className`    | Ingress class name       | `""`                       |
| `ingress.annotations`  | Ingress annotations      | `{}`                       |
| `ingress.hosts`        | Ingress hosts            | `[{host: chart-example.local}]` |
| `ingress.tls`          | Ingress TLS config       | `[]`                       |

### HTTPRoute Configuration

| Parameter                | Description                  | Default              |
| ------------------------ | ---------------------------- | -------------------- |
| `httpRoute.enabled`      | Enable HTTPRoute             | `false`              |
| `httpRoute.annotations`  | HTTPRoute annotations        | `{}`                 |
| `httpRoute.parentRefs`   | Gateway references           | See values.yaml      |
| `httpRoute.hostnames`    | Route hostnames              | `[chart-example.local]` |
| `httpRoute.rules`        | Route rules                  | See values.yaml      |

### Resources

| Parameter                  | Description              | Default |
| -------------------------- | ------------------------ | ------- |
| `resources.limits.cpu`     | CPU limit                | `""`    |
| `resources.limits.memory`  | Memory limit             | `""`    |
| `resources.requests.cpu`   | CPU request              | `""`    |
| `resources.requests.memory`| Memory request           | `""`    |

### Health Probes

| Parameter                                | Description                     | Default |
| ---------------------------------------- | ------------------------------- | ------- |
| `livenessProbe.initialDelaySeconds`      | Liveness probe initial delay    | `20`    |
| `livenessProbe.periodSeconds`            | Liveness probe period           | `10`    |
| `readinessProbe.initialDelaySeconds`     | Readiness probe initial delay   | `10`    |
| `readinessProbe.periodSeconds`           | Readiness probe period          | `5`     |
| `startupProbe.failureThreshold`          | Startup probe failure threshold | `30`    |
| `startupProbe.periodSeconds`             | Startup probe period            | `5`     |

### Autoscaling

| Parameter                                   | Description                    | Default |
| ------------------------------------------- | ------------------------------ | ------- |
| `autoscaling.enabled`                       | Enable autoscaling             | `false` |
| `autoscaling.minReplicas`                   | Minimum replicas               | `1`     |
| `autoscaling.maxReplicas`                   | Maximum replicas               | `100`   |
| `autoscaling.targetCPUUtilizationPercentage`| Target CPU utilization        | `80`    |

### Volumes and Storage

| Parameter       | Description             | Default |
| --------------- | ----------------------- | ------- |
| `volumes`       | Additional volumes      | `[]`    |
| `volumeMounts`  | Additional volume mounts| `[]`    |

### Extra Environment Variables

| Parameter      | Description                      | Default |
| -------------- | -------------------------------- | ------- |
| `extraEnv`     | Extra environment variables      | `[]`    |
| `extraEnvFrom` | Extra environment from ConfigMap/Secret | `[]` |

### Node Scheduling

| Parameter       | Description         | Default |
| --------------- | ------------------- | ------- |
| `nodeSelector`  | Node selector       | `{}`    |
| `tolerations`   | Pod tolerations     | `[]`    |
| `affinity`      | Pod affinity        | `{}`    |

## Examples

### Production Deployment with PostgreSQL

```yaml
replicaCount: 2

kener:
  nodeEnv: production
  origin: https://status.mycompany.com
  keyFrom:
    secretRef: kener-secrets
    secretKey: encryption-key

database:
  enabled: true
  existingSecret: postgres-credentials
  secretKeys:
    url: connection-string

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
  hosts:
    - host: status.mycompany.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: status-tls-cert
      hosts:
        - status.mycompany.com

resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 100m
    memory: 128Mi

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 70
```

### Deployment with Gateway API

```yaml
kener:
  nodeEnv: production
  origin: https://status.example.io

database:
  enabled: true
  url: "postgresql://kener:password@postgres-service:5432/kener"

httpRoute:
  enabled: true
  annotations:
    route.gateway.io/cors-enabled: "true"
  parentRefs:
    - name: external-gateway
      sectionName: https
      namespace: gateway-system
  hostnames:
    - status.example.io
  rules:
    - matches:
      - path:
          type: PathPrefix
          value: /
```

### Development Environment

```yaml
replicaCount: 1

kener:
  nodeEnv: development
  origin: http://localhost:3000
  key: "dev-key-not-for-production"

database:
  enabled: true
  url: "postgresql://kener:password@postgres:5432/kener_dev"

service:
  type: NodePort
  port: 3000

resources:
  limits:
    cpu: 200m
    memory: 256Mi
  requests:
    cpu: 50m
    memory: 64Mi
```

## Troubleshooting

### Check Pod Status

```bash
kubectl get pods -n monitoring
kubectl logs -n monitoring <pod-name>
```

### Access the Application

```bash
# Port-forward for local testing
kubectl port-forward -n monitoring svc/my-status-kener 3000:3000

# Access at http://localhost:3000
```

### Debug Database Connection

```bash
# Check database connectivity
kubectl exec -n monitoring <pod-name> -- env | grep DATABASE

# Test database connection
kubectl run -it --rm debug --image=postgres:latest --restart=Never -- \
  psql postgresql://user:password@host:port/db
```

### Common Issues

1. **Application Not Starting**: Check database connection string and ensure PostgreSQL is accessible
2. **Ingress Not Working**: Verify ingress controller is installed and className is correct
3. **Permissions Issues**: Ensure proper security contexts are configured
4. **Database Migration Errors**: Check database permissions and schema initialization

## Database Setup

Kener requires a PostgreSQL database. Here's a quick setup example:

```bash
# Install PostgreSQL using Helm
helm install postgres bitnami/postgresql \
  --set auth.database=kener \
  --set auth.username=kener \
  --set auth.password=your-secure-password

# Get the database URL
export POSTGRES_URL="postgresql://kener:your-secure-password@postgres-postgresql:5432/kener"
```

## Security Considerations

- Always use secrets for sensitive data (encryption keys, database passwords)
- Enable TLS/HTTPS for production deployments
- Use strong encryption keys (minimum 32 characters)
- Regularly update to latest Kener versions
- Implement network policies to restrict access
- Use non-root security contexts when possible

## License

This project is licensed under the MIT License. See the [LICENSE.md](LICENSE.md) file for details.

## Maintainers

**Maintainer:**
- David Gheghea - david.gheghea@unxwares.com

## Links

- [Kener Official Website](https://kener.ing)
- [Kener GitHub Repository](https://github.com/rajnandan1/kener)
- [UnxWares Helm Repository](https://github.com/UnxWares/helm)

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
