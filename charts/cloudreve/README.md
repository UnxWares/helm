# Cloudreve Helm Chart

A Helm chart for deploying Cloudreve, a self-hosted file management and sharing system with support for multiple storage providers.

## Overview

Cloudreve is a feature-rich, self-hosted cloud storage system that supports multiple storage backends including local storage, OneDrive, Amazon S3, Alibaba Cloud OSS, Tencent Cloud COS, and many more. This Helm chart makes it easy to deploy Cloudreve on Kubernetes with database integration and persistent storage.

## Features

- **Multi-Storage Support**: Local, OneDrive, S3, OSS, COS, and more storage backends
- **User-Friendly Interface**: Modern web interface for file management
- **Share Management**: Easy file sharing with customizable permissions
- **Database Integration**: MySQL/PostgreSQL/SQLite support
- **Persistent Storage**: Configurable persistent volume support
- **Ingress Support**: Easy exposure via ingress controllers
- **Auto-scaling**: Optional horizontal pod autoscaling
- **Flexible Configuration**: ConfigMap or Secret-based configuration

## Installation

### Add the Helm Repository

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
```

### Install the Chart

```bash
helm install my-storage unxwares/cloudreve \
  --namespace storage \
  --create-namespace
```

## Configuration

### Basic Installation with MySQL

```yaml
database:
  type: mysql
  host: mysql-service
  port: 3306
  name: cloudreve
  user: cloudreve
  password: your-secure-password

persistence:
  enabled: true
  size: 50Gi
  storageClassName: standard

ingress:
  enabled: true
  className: nginx
  hosts:
    - host: files.mycompany.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: files-tls
      hosts:
        - files.mycompany.com
```

### Using Existing Database Secret

```yaml
database:
  existingSecret: cloudreve-db-credentials
  # The secret should contain: user, password
  # Optionally: type, host, port, name

persistence:
  enabled: true
  size: 100Gi
```

### Custom Configuration via ConfigMap

```yaml
createConfigmap: true

confini:
  fromSecret: false
  data: |
    [System]
    Mode = master
    Listen = :5212
    Debug = false
    SessionSecret = your-secure-session-secret
    HashIDSalt = your-secure-hash-salt

    [Database]
    Type = mysql
    Port = 3306
    DBFile = cloudreve.db

    [Redis]
    Server = redis-service:6379
    Password =
    DB = 0
```

### Using Configuration from Secret

```yaml
confini:
  fromSecret: true
  secretName: cloudreve-config
```

## Configuration Options

### Global Settings

| Parameter             | Description                    | Default              |
| --------------------- | ------------------------------ | -------------------- |
| `replicaCount`        | Number of replicas             | `1`                  |
| `image.repository`    | Container image repository     | `cloudreve/cloudreve`|
| `image.tag`           | Container image tag            | `3.8.0`              |
| `image.pullPolicy`    | Image pull policy              | `Always`             |
| `imagePullSecrets`    | Image pull secrets             | `[]`                 |
| `nameOverride`        | Override chart name            | `""`                 |
| `fullnameOverride`    | Override full chart name       | `""`                 |
| `namespaceOverride`   | Override deployment namespace  | `""`                 |
| `labels`              | Deployment labels              | `{}`                 |
| `annotations`         | Deployment annotations         | `{}`                 |

### Service Account

| Parameter                        | Description                      | Default |
| -------------------------------- | -------------------------------- | ------- |
| `serviceAccount.create`          | Create service account           | `true`  |
| `serviceAccount.annotations`     | Service account annotations      | `{}`    |
| `serviceAccount.name`            | Service account name             | `""`    |

### Service Configuration

| Parameter            | Description              | Default     |
| -------------------- | ------------------------ | ----------- |
| `service.type`       | Service type             | `ClusterIP` |
| `service.port`       | Service port             | `80`        |
| `service.targetPort` | Container target port    | `5212`      |
| `podPortName`        | Pod port name            | `cloudreve` |

### Ingress Configuration

| Parameter              | Description              | Default                    |
| ---------------------- | ------------------------ | -------------------------- |
| `ingress.enabled`      | Enable ingress           | `false`                    |
| `ingress.className`    | Ingress class name       | `""`                       |
| `ingress.annotations`  | Ingress annotations      | `{}`                       |
| `ingress.hosts`        | Ingress hosts            | `[{host: chart-example.local}]` |
| `ingress.tls`          | Ingress TLS config       | `[]`                       |

### Database Configuration

| Parameter                           | Description                      | Default    |
| ----------------------------------- | -------------------------------- | ---------- |
| `database.type`                     | Database type (mysql/postgresql/sqlite) | `mysql` |
| `database.host`                     | Database host                    | `127.0.0.1`|
| `database.port`                     | Database port                    | `3306`     |
| `database.name`                     | Database name                    | `v3`       |
| `database.user`                     | Database user                    | `root`     |
| `database.password`                 | Database password                | `root`     |
| `database.existingSecret`           | Use existing secret for DB creds | `""`       |
| `database.existingSecretKeys.type`  | Key for DB type in secret        | `type`     |
| `database.existingSecretKeys.host`  | Key for DB host in secret        | `host`     |
| `database.existingSecretKeys.port`  | Key for DB port in secret        | `port`     |
| `database.existingSecretKeys.name`  | Key for DB name in secret        | `name`     |
| `database.existingSecretKeys.user`  | Key for DB user in secret        | `user`     |
| `database.existingSecretKeys.password` | Key for DB password in secret | `password` |

### Persistence Configuration

| Parameter                     | Description                        | Default           |
| ----------------------------- | ---------------------------------- | ----------------- |
| `persistence.type`            | Persistence type                   | `pvc`             |
| `persistence.enabled`         | Enable persistence                 | `false`           |
| `persistence.storageClassName`| Storage class name                 | `default`         |
| `persistence.accessModes`     | Access modes                       | `[ReadWriteOnce]` |
| `persistence.size`            | Persistent volume size             | `10Gi`            |
| `persistence.finalizers`      | PVC finalizers                     | `[kubernetes.io/pvc-protection]` |
| `persistence.extraPvcLabels`  | Extra labels for PVC               | `{}`              |
| `persistence.existingClaim`   | Use existing PVC                   | `""`              |
| `persistence.subPath`         | Sub-path of PV to mount            | `""`              |
| `persistence.inMemory.enabled`| Use in-memory storage when disabled| `true`            |
| `persistence.inMemory.sizeLimit` | Memory size limit               | `""`              |

### Configuration File Settings

| Parameter                | Description                         | Default |
| ------------------------ | ----------------------------------- | ------- |
| `createConfigmap`        | Create ConfigMap for configuration  | `true`  |
| `confini.fromSecret`     | Load conf.ini from Secret           | `false` |
| `confini.secretName`     | Secret name containing conf.ini     | `""`    |
| `confini.data`           | Configuration data (INI format)     | See values.yaml |

### Resources

| Parameter                  | Description              | Default |
| -------------------------- | ------------------------ | ------- |
| `resources.limits.cpu`     | CPU limit                | `""`    |
| `resources.limits.memory`  | Memory limit             | `""`    |
| `resources.requests.cpu`   | CPU request              | `""`    |
| `resources.requests.memory`| Memory request           | `""`    |

### Autoscaling

| Parameter                                   | Description                    | Default |
| ------------------------------------------- | ------------------------------ | ------- |
| `autoscaling.enabled`                       | Enable autoscaling             | `false` |
| `autoscaling.minReplicas`                   | Minimum replicas               | `1`     |
| `autoscaling.maxReplicas`                   | Maximum replicas               | `100`   |
| `autoscaling.targetCPUUtilizationPercentage`| Target CPU utilization        | `80`    |

### Pod Configuration

| Parameter              | Description                | Default |
| ---------------------- | -------------------------- | ------- |
| `podAnnotations`       | Pod annotations            | `{}`    |
| `podLabels`            | Pod labels                 | `{}`    |
| `podSecurityContext`   | Pod security context       | `{}`    |
| `securityContext`      | Container security context | `{}`    |

### Node Scheduling

| Parameter       | Description         | Default |
| --------------- | ------------------- | ------- |
| `nodeSelector`  | Node selector       | `{}`    |
| `tolerations`   | Pod tolerations     | `[]`    |
| `affinity`      | Pod affinity        | `{}`    |

## Examples

### Production Setup with MySQL and S3

```yaml
replicaCount: 2

database:
  type: mysql
  host: mysql-service.database.svc.cluster.local
  port: 3306
  name: cloudreve
  existingSecret: cloudreve-mysql-credentials

persistence:
  enabled: true
  size: 100Gi
  storageClassName: fast-ssd
  accessModes:
    - ReadWriteMany

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "1024m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
  hosts:
    - host: files.mycompany.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: cloudreve-tls
      hosts:
        - files.mycompany.com

resources:
  limits:
    cpu: 1000m
    memory: 2Gi
  requests:
    cpu: 250m
    memory: 512Mi

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 70

confini:
  fromSecret: false
  data: |
    [System]
    Mode = master
    Listen = :5212
    Debug = false
    SessionSecret = your-secure-session-secret-change-this
    HashIDSalt = your-secure-hash-salt-change-this

    [Database]
    Type = mysql
    Port = 3306

    [CORS]
    AllowOrigins = https://files.mycompany.com
    AllowMethods = GET,POST,PUT,PATCH,DELETE
    AllowHeaders = *
    AllowCredentials = true
```

### PostgreSQL with Redis

```yaml
database:
  type: postgresql
  host: postgresql-service
  port: 5432
  name: cloudreve
  user: cloudreve
  password: secure-password

persistence:
  enabled: true
  size: 50Gi

confini:
  fromSecret: false
  data: |
    [System]
    Mode = master
    Listen = :5212

    [Database]
    Type = postgresql
    Port = 5432

    [Redis]
    Server = redis-service:6379
    Password =
    DB = 0
```

### Development Setup with SQLite

```yaml
replicaCount: 1

database:
  type: sqlite

persistence:
  enabled: true
  size: 10Gi

service:
  type: NodePort

confini:
  fromSecret: false
  data: |
    [System]
    Mode = master
    Listen = :5212
    Debug = true

    [Database]
    Type = sqlite3
    DBFile = /data/cloudreve.db
```

## Troubleshooting

### Check Pod Status

```bash
kubectl get pods -n storage
kubectl logs -n storage <pod-name>
```

### Access Application Logs

```bash
kubectl logs -n storage <pod-name> --tail=100 -f
```

### Verify Configuration

```bash
# View ConfigMap
kubectl get configmap -n storage
kubectl describe configmap cloudreve-config -n storage

# Check database connection
kubectl exec -n storage <pod-name> -- cat /app/conf.ini
```

### Common Issues

1. **Database Connection Failed**: Verify database credentials and ensure database service is accessible
2. **Permission Denied on Storage**: Check PVC permissions and pod security contexts
3. **Upload Fails**: Increase `nginx.ingress.kubernetes.io/proxy-body-size` annotation for larger files
4. **Session Issues**: Ensure SessionSecret is set and consistent across pod restarts

## Initial Setup

After deploying Cloudreve:

1. **Access the application** via ingress hostname or service
2. **First login** - Default admin account will be created on first run
3. **Check logs** for initial admin password: `kubectl logs -n storage <pod-name>`
4. **Change password** immediately after first login
5. **Configure storage policies** in the admin panel
6. **Set up users and groups** as needed

## Storage Backends

Cloudreve supports various storage backends. Configure them in the admin panel after deployment:

- **Local Storage**: Uses the persistent volume
- **OneDrive**: Microsoft OneDrive integration
- **Amazon S3**: S3-compatible storage
- **Alibaba Cloud OSS**: Alibaba cloud storage
- **Tencent Cloud COS**: Tencent cloud storage
- **Qiniu Kodo**: Qiniu cloud storage
- **Upyun**: Upyun cloud storage

## Security Considerations

- Always change default SessionSecret and HashIDSalt
- Use secrets for database credentials
- Enable HTTPS/TLS for production
- Implement proper RBAC and network policies
- Regular backups of database and storage
- Keep Cloudreve updated to latest version
- Use strong passwords for admin accounts
- Configure CORS properly for your domain

## Performance Tuning

For better performance:

- Use ReadWriteMany access mode with multiple replicas
- Enable Redis for caching and session storage
- Configure appropriate resource limits
- Use fast storage classes (SSD)
- Enable CDN for static files
- Configure proper ingress timeouts for large uploads

## License

This project is licensed under the MIT License. See the [LICENSE.md](LICENSE.md) file for details.

## Maintainers

**Maintainer:**
- David Gheghea - david.gheghea@unxwares.com

**Co-Maintainer:**
- Baptiste Gosselin - baptiste.gosselin@unxwares.com

## Links

- [Cloudreve Official Website](https://cloudreve.org/)
- [Cloudreve Documentation](https://docs.cloudreve.org/)
- [Cloudreve GitHub Repository](https://github.com/cloudreve/Cloudreve)
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
