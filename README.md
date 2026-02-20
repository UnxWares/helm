<div align="center">
  <img src="https://github.com/UnxWares/.github/blob/main/unxwares-logo.png?raw=true" align="center" height="" width="400" />
</div>

# <div align="center">UnxWares Helm Charts</div>

A curated collection of production-ready Helm charts for Kubernetes deployments, maintained by UnxWares.

[Charts](#available-charts) • [Installation](#installation) • [Contributing](#contributing) • [Support](#support)

</div>

---

## Overview

This repository contains Helm charts designed for production Kubernetes environments. Each chart is carefully maintained to provide reliable, secure, and scalable deployments with sensible defaults and extensive customization options.

## Available Charts

### OpenEverest Database Tools

Database initialization and management tools for OpenEverest clusters.

- **Chart Version:** 2026.2.11
- **Description:** Automated database creation, initialization scripts, and ArgoCD integration for MySQL, PostgreSQL, and MongoDB
- **Documentation:** [charts/openeverest-database-tools/README.md](charts/openeverest-database-tools/README.md)

**Key Features:**

- Multi-database support (MySQL, PostgreSQL, MongoDB)
- Automated database initialization
- Custom SQL script execution
- Native ArgoCD integration with sync waves
- Secure credential management

### Bind9

Production-ready ISC Bind9 DNS server for Kubernetes.

- **Chart Version:** 2026.2.22
- **App Version:** 9.21
- **Description:** Flexible and production-ready authoritative DNS server deployment
- **Documentation:** [charts/bind9/README.md](charts/bind9/README.md)
- **Upstream:** [ISC Bind9](https://www.isc.org/bind/)

**Key Features:**

- Full-featured DNS server
- Zone management support
- Persistence options
- Kubernetes-native configuration

### Cloudreve

Self-hosted file management and sharing system.

- **Chart Version:** 2026.2.4
- **App Version:** 3.8.0
- **Description:** Self-hosted file management system with multiple storage provider support
- **Documentation:** [charts/cloudreve/README.md](charts/cloudreve/README.md)
- **Upstream:** [Cloudreve](https://cloudreve.org/)

**Key Features:**

- Multiple storage backends
- User-friendly web interface
- Share management
- Cloud storage integration

### Kener

Modern status page application.

- **Chart Version:** 2026.2.5
- **App Version:** 3.2.19
- **Description:** Beautiful and responsive status page for monitoring your services
- **Documentation:** [charts/kener/README.md](charts/kener/README.md)
- **Upstream:** [Kener](https://kener.ing)

**Key Features:**

- Modern status page interface
- Database integration (PostgreSQL)
- HTTPRoute and Ingress support
- Customizable monitoring

## Installation

### Add the Helm Repository

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
```

### Install a Chart

```bash
# Install OpenEverest Database Tools
helm install my-release unxwares/openeverest-database-tools

# Install Bind9
helm install my-dns unxwares/bind9

# Install Cloudreve
helm install my-storage unxwares/cloudreve
```

### Custom Configuration

```bash
# Using a custom values file
helm install my-release unxwares/openeverest-database-tools -f values.yaml

# Override specific values
helm install my-release unxwares/openeverest-database-tools \
  --set global.namespace=my-namespace \
  --set rbac.create=true
```

## Versioning

All charts in this repository follow a **calendar-based versioning scheme**:

```
year.month.version_number
```

### Version Format

- **Year**: 4-digit year (e.g., `2026`)
- **Month**: Month number without leading zero (e.g., `3` for March, `12` for December)
- **Version Number**: Sequential number starting from 1 for each month

### Examples

- `2026.3.1` - First version released in March 2026
- `2026.3.2` - Second version released in March 2026 (even if released on March 28th)
- `2026.4.1` - First version released in April 2026

### Version Increments

- Each new release in a month increments the version number
- Version numbers reset to 1 at the beginning of each new month
- The actual day of release within the month doesn't affect the version number

This versioning scheme makes it easy to track when changes were made and ensures chronological ordering of releases.

## Verified Publisher on Artifact Hub

This repository is configured as a **Verified Publisher** on Artifact Hub, which provides users with confidence that the charts are maintained by the official UnxWares team.

### How It Works

The verification is done through the `artifacthub-repo.yml` file located at the root of this repository. This file contains:
- **Repository ID**: The unique identifier from Artifact Hub
- **Owners**: List of maintainers and their contact information

The file is automatically deployed to GitHub Pages alongside the chart repository `index.yaml` during the release process.

### Repository ID Configuration

To maintain the verified status:
1. Log in to [Artifact Hub Control Panel](https://artifacthub.io/control-panel)
2. Navigate to the **Repositories** tab
3. Find your repository ID (displayed on the repository card)
4. Ensure the `repositoryID` field in `artifacthub-repo.yml` matches this ID

The verified publisher badge will appear after the next repository synchronization (triggered when `index.yaml` changes).

## Values Schema

All charts include a **values schema** (`values.schema.json`) that:
- ✅ Validates user-provided values
- ✅ Provides rich documentation on Artifact Hub
- ✅ Enables IDE autocompletion
- ✅ Prevents configuration errors

### Generating Schemas

To regenerate schemas after modifying `values.yaml`:

```bash
# Run the automated script
./generate-schemas.sh
```

Or manually for a specific chart:

```bash
# Install the plugin (first time only)
helm plugin install https://github.com/karuppiah7890/helm-schema-gen.git

# Generate schema
helm schema-gen charts/bind9/values.yaml > charts/bind9/values.schema.json
```

### Schema Benefits

Users installing your charts benefit from:
- **Validation**: Helm validates values against the schema before installation
- **Documentation**: Artifact Hub displays an interactive schema documentation
- **Type Safety**: Catch configuration errors early in the deployment process

## Chart Development

### Directory Structure

```
.
├── charts/
│   ├── bind9/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   ├── templates/
│   │   └── README.md
│   ├── cloudreve/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   ├── templates/
│   │   └── README.md
│   ├── kener/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   ├── templates/
│   │   └── README.md
│   └── openeverest-database-tools/
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── templates/
│       └── README.md
├── README.md
└── CONTRIBUTING.md
```

### Testing Charts Locally

```bash
# Lint a chart
helm lint charts/openeverest-database-tools

# Template to see rendered manifests
helm template my-release charts/openeverest-database-tools

# Install from local chart
helm install my-release ./charts/openeverest-database-tools
```

## Requirements

- Kubernetes 1.19+
- Helm 3.0+

Specific charts may have additional requirements. Please refer to individual chart documentation for details.

## Documentation

Each chart includes comprehensive documentation in its respective directory:

- **Chart README:** Installation instructions, configuration options, and examples
- **values.yaml:** Annotated configuration with defaults and explanations
- **Chart.yaml:** Chart metadata and dependencies

## Support

### Questions and General Support

For general questions, support inquiries, or discussions about our charts:

**Email:** opensource@unxwares.com

### Bug Reports and Feature Requests

Please report issues or request features on our [GitHub Issues](https://github.com/UnxWares/helm/issues) page.

When reporting a bug, please include:

- Chart name and version
- Kubernetes version
- Helm version
- Steps to reproduce
- Expected vs actual behavior

### Security Vulnerabilities

If you discover a security vulnerability, please DO NOT open a public issue.

**Email security issues to:** security@unxwares.com

We take security seriously and will respond promptly to all security-related concerns.

## Contributing

We welcome contributions from the community! Whether you're fixing bugs, improving documentation, or adding new features, your contributions are appreciated.

Please see our [CONTRIBUTING.md](CONTRIBUTING.md) file for detailed guidelines on how to contribute.

## License

This project is licensed under the MIT License. See individual chart LICENSE files for details.

## Maintainers

**Maintainer:**

- David Gheghea - david.gheghea@unxwares.com

**Co-Maintainer:**

- Baptiste Gosselin - baptiste.gosselin@unxwares.com

## Links

- [UnxWares Website](https://unxwares.com)
- [GitHub Repository](https://github.com/UnxWares/helm)
- [Helm Repository](https://helm.unxwares.studio)
- [Artifact Hub](https://artifacthub.io/packages/search?repo=unxwares)

---

<div align="center">
  <strong>Made with ❤️ by the UnxWares Team</strong>
</div>
