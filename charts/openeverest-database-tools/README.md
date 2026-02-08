# OpenEverest Database Tools

A Helm chart providing database initialization and management tools for [OpenEverest](https://openeverest.io) deployments by UnxWares.

## Overview

OpenEverest Database Tools is a collection of additional tools and features designed to streamline database management within OpenEverest clusters. This chart enables automatic database creation, initialization script execution, and seamless ArgoCD integration for database lifecycle management.

## Features

- **Multi-Database Support**: Automated initialization for MySQL, PostgreSQL, and MongoDB
- **Database Creation**: Automatically create databases within your cluster at deployment time
- **Init Scripts**: Execute custom SQL commands at startup
- **ArgoCD Integration**: Automatic job re-execution on configuration changes via sync waves
- **Credential Management**: Secure integration with Kubernetes secrets
- **Customizable Jobs**: Per-database configuration with resource limits, TTL, and retry policies
- **RBAC Support**: Optional RBAC resources for secure cluster operations

## Installation

> **NOTE:** OpenEverest Database Tools must be installed in an OpenEverest managed namespace. For more information, see the [OpenEverest documentation on managing namespaces](https://openeverest.io/documentation/1.13.0/administer/manage_namespaces.html?h=namespace).

### Add the Helm Repository

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
```

### Install the Chart

```bash
helm install openeverest-database-tools unxwares/openeverest-database-tools \
  --namespace everest-system \
  --create-namespace
```

## Configuration

### PostgreSQL Example

```yaml
databases:
  postgresql:
    - name: my-app-db-init
      clusterName: my-dev-pg-cluster
      credentialsSecret: my-dev-pg-cluster-credentials
      databases:
        - laravel-app
        - laravel-cache
      initScripts:
        - CREATE EXTENSION IF NOT EXISTS pg_trgm;
        - CREATE EXTENSION IF NOT EXISTS pgcrypto;
        - CREATE TABLE IF NOT EXISTS migrations (id SERIAL PRIMARY KEY);
```

### MySQL Example

```yaml
databases:
  mysql:
    - name: wordpress-db-init
      clusterName: wordpress-mysql-cluster
      credentialsSecret: wordpress-mysql-cluster-credentials
      databases:
        - wordpress
        - wordpress_cache
      initScripts:
        - CREATE TABLE IF NOT EXISTS init_log (id INT AUTO_INCREMENT PRIMARY KEY, message VARCHAR(255));
        - INSERT INTO init_log (message) VALUES ('Database initialized');
```

### MongoDB Example

```yaml
databases:
  mongodb:
    - name: app-mongo-init
      clusterName: app-mongo-cluster
      credentialsSecret: app-mongo-cluster-credentials
      databases:
        - appdb
      collections:
        - name: users
          database: appdb
        - name: sessions
          database: appdb
      initScripts:
        - db.users.createIndex({ "email": 1 }, { unique: true });
        - db.sessions.createIndex({ "createdAt": 1 }, { expireAfterSeconds: 3600 });
```

## ArgoCD Integration

This chart includes built-in support for ArgoCD synchronization hooks, allowing database initialization jobs to automatically re-run when configurations change.

### Default ArgoCD Configuration

```yaml
global:
  argocd:
    enabled: true
    hook: Sync
    syncOptions: Replace=true
    hookDeletePolicy: HookSucceeded
```

### How It Works

- Jobs are executed during the ArgoCD `Sync` phase
- Completed jobs are automatically deleted after successful execution
- Configuration changes trigger automatic re-initialization
- Sync waves ensure proper execution order

### Disabling ArgoCD Integration

```yaml
global:
  argocd:
    enabled: false
```

## Configuration Options

### Global Settings

| Parameter                        | Description                                   | Default             |
| -------------------------------- | --------------------------------------------- | ------------------- |
| `global.namespace`               | Namespace where database clusters are located | `everest-databases` |
| `global.argocd.enabled`          | Enable ArgoCD integration                     | `true`              |
| `global.argocd.hook`             | ArgoCD hook type                              | `Sync`              |
| `global.argocd.hookDeletePolicy` | Hook deletion policy                          | `HookSucceeded`     |
| `global.ttlSecondsAfterFinished` | Job TTL after completion (seconds)            | `180`               |
| `global.backoffLimit`            | Job retry limit                               | `5`                 |
| `global.restartPolicy`           | Job restart policy                            | `OnFailure`         |

### RBAC Settings

| Parameter                 | Description           | Default   |
| ------------------------- | --------------------- | --------- |
| `rbac.create`             | Create RBAC resources | `true`    |
| `rbac.serviceAccountName` | Service account name  | `default` |

### Database Configuration

Each database type (`postgresql`, `mysql`, `mongodb`) supports the following parameters:

| Parameter                 | Description                       | Required |
| ------------------------- | --------------------------------- | -------- |
| `name`                    | Job name                          | Yes      |
| `clusterName`             | Database cluster name             | Yes      |
| `credentialsSecret`       | Secret containing credentials     | Yes      |
| `databases`               | List of databases to create       | Yes      |
| `initScripts`             | SQL/JavaScript scripts to execute | No       |
| `ttlSecondsAfterFinished` | Override global TTL               | No       |
| `backoffLimit`            | Override global backoff limit     | No       |
| `image`                   | Override default image            | No       |
| `env`                     | Additional environment variables  | No       |
| `annotations`             | Additional annotations            | No       |
| `labels`                  | Additional labels                 | No       |

### Image Settings

| Parameter          | Description             | Default        |
| ------------------ | ----------------------- | -------------- |
| `image.postgresql` | PostgreSQL client image | `alpine:3.19`  |
| `image.mysql`      | MySQL client image      | `alpine:3.19`  |
| `image.mongodb`    | MongoDB client image    | `alpine:3.19`  |
| `image.pullPolicy` | Image pull policy       | `IfNotPresent` |

## Examples

### Complete Example with Multiple Databases

```yaml
global:
  namespace: everest-databases
  argocd:
    enabled: true
  ttlSecondsAfterFinished: 300

databases:
  postgresql:
    - name: main-app-db
      clusterName: production-pg
      credentialsSecret: production-pg-credentials
      databases:
        - appdb
        - analytics
      initScripts:
        - CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
        - CREATE SCHEMA IF NOT EXISTS app;

  mysql:
    - name: legacy-app-db
      clusterName: legacy-mysql
      credentialsSecret: legacy-mysql-credentials
      databases:
        - legacy_prod
      initScripts:
        - SET GLOBAL max_connections = 500;

  mongodb:
    - name: cache-db
      clusterName: cache-mongo
      credentialsSecret: cache-mongo-credentials
      databases:
        - cache
      collections:
        - name: sessions
          database: cache
        - name: temp_data
          database: cache
```

### Custom Resource Limits

```yaml
resources:
  limits:
    cpu: 200m
    memory: 256Mi
  requests:
    cpu: 100m
    memory: 128Mi

securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 1000
```

## Troubleshooting

### Check Job Status

```bash
kubectl get jobs -n everest-databases
kubectl logs job/<job-name> -n everest-databases
```

### Debug Failed Initialization

```bash
kubectl describe job/<job-name> -n everest-databases
kubectl get events -n everest-databases --sort-by='.lastTimestamp'
```

### Common Issues

1. **Credentials Not Found**: Ensure the `credentialsSecret` exists in the correct namespace
2. **Permission Denied**: Verify RBAC settings and service account permissions
3. **Connection Timeout**: Check network policies and database cluster accessibility

## License

This project is licensed under the MIT License. See the [LICENSE.md](LICENSE.md) file for details.

## Maintainers

**Maintainer:**
- David Gheghea - david.gheghea@unxwares.com

**Co-Maintainer:**
- Baptiste Gosselin - baptiste.gosselin@unxwares.com

## Links

- [OpenEverest Official Website](https://openeverest.io)
- [GitHub Repository](https://github.com/UnxWares/helm)

---

## Contributing

We welcome contributions from the community! If you'd like to contribute to OpenEverest Database Tools:

1. **Fork the Repository**: Create your own fork of the project
2. **Create a Feature Branch**: `git checkout -b feature/your-feature-name`
3. **Make Your Changes**: Implement your feature or bug fix
4. **Test Thoroughly**: Ensure your changes work as expected
5. **Commit Your Changes**: Use clear and descriptive commit messages
6. **Push to Your Fork**: `git push origin feature/your-feature-name`
7. **Open a Pull Request**: Submit a PR to the main repository with a detailed description

### Reporting Issues

If you encounter bugs or have feature requests, please open an issue on our [GitHub repository](https://github.com/UnxWares/helm/issues).

### Security Vulnerabilities

If you discover a security vulnerability, please DO NOT open a public issue. Instead, email us directly at:

**security@unxwares.com**

We take security seriously and will respond promptly to all security-related concerns.

### Questions and Support

For general questions, support, or inquiries about our open source initiative:

**opensource@unxwares.com**

---

**Made with ❤️ by the UnxWares Team**
