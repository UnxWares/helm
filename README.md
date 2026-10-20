<div align="center">
  <img src="https://github.com/UnxWares/.github/blob/main/unxwares-logo.png?raw=true" align="center" height="" width="400" />
</div>

# <div align="center">UnxWares Helm Charts</div>

<div align="center">

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/unxwares)](https://artifacthub.io/packages/search?repo=unxwares)
[![Release Charts](https://github.com/UnxWares/helm/actions/workflows/release.yaml/badge.svg)](https://github.com/UnxWares/helm/actions/workflows/release.yaml)
[![Image scan](https://github.com/UnxWares/helm/actions/workflows/image-scan.yaml/badge.svg)](https://github.com/UnxWares/helm/actions/workflows/image-scan.yaml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.md)

[Charts](#available-charts) • [Installation](#installation) • [Signatures](#verifying-signatures) • [Contributing](#contributing) • [Support](#support)

</div>

---

Helm charts we run ourselves, maintained by UnxWares. Every chart follows the same rules:

- **Pinned, current images**, scanned weekly with Trivy; releases that only bump images for CVEs are flagged
  `containsSecurityUpdates` on Artifact Hub.
- **No default passwords**: secrets are generated once and kept across upgrades, or read from your own Secret, and
  reach containers through `secretKeyRef` only.
- **Hardened by default**: non-root wherever the image allows it, read-only root filesystem, capabilities dropped,
  seccomp `RuntimeDefault`, no service account token unless the workload talks to the Kubernetes API.
- **Values schema** (`values.schema.json`) and a README generated from the annotated `values.yaml`.
- **Signed packages** (Helm provenance files) and CI on every pull request: `helm lint --strict` on Helm 3 and 4,
  kubeconform, chart-testing installs on kind, Artifact Hub lint.

## Available charts

| Chart | Application | Description |
|-------|-------------|-------------|
| [bind9](charts/bind9) | ISC BIND 9.20 | Authoritative DNS server, with an optional Prometheus exporter |
| [cloudreve](charts/cloudreve) | Cloudreve 4.19 | Self-hosted file management and sharing (SQLite, PostgreSQL, MySQL, Redis) |
| [excalidash](charts/excalidash) | ExcaliDash 0.6 | Dashboard and organizer for Excalidraw drawings, with live collaboration and OIDC |
| [fossflow](charts/fossflow) | FossFLOW 1.0 | Isometric infrastructure diagrams, with server-side storage |
| [kener](charts/kener) | Kener 4.1 | Status page with a bundled Valkey, SQLite or external PostgreSQL/MySQL |
| [laravel-generic](charts/laravel-generic) | Laravel 12 | Deploy your own Laravel image: FrankenPHP or PHP-FPM + nginx, queue workers, scheduler, migrations |
| [openeverest-database-tools](charts/openeverest-database-tools) | OpenEverest 1.17 | Create databases, users and run init scripts on OpenEverest PostgreSQL, MySQL and MongoDB clusters |
| [powerdns](charts/powerdns) | PowerDNS Auth 5.1 / Recursor 5.4 | Authoritative DNS with its REST API (SQLite, PostgreSQL, MySQL) and an optional recursor |
| [taiga](charts/taiga) | Taiga 6.10 | Agile project management: backend, workers, events, front, bundled PostgreSQL and RabbitMQ |

Each chart README lists every value, examples and the upgrade notes between releases.

## Installation

```bash
helm repo add unxwares https://helm.unxwares.studio
helm repo update
helm search repo unxwares

helm install my-dns unxwares/powerdns --namespace dns --create-namespace
```

## Verifying signatures

Packages are signed with the **UnxWares Helm Charts** OpenPGP key
(`7902 E52E A435 EF27 C643  2E53 78D6 B532 C599 DA9B`, published at
<https://helm.unxwares.studio/pgp-public-key.asc>):

```bash
curl -fsSL https://helm.unxwares.studio/pgp-public-key.asc | gpg --import
gpg --export 7902E52EA435EF27C6432E5378D6B532C599DA9B > ~/.gnupg/unxwares-helm.gpg
helm install my-dns unxwares/powerdns --verify --keyring ~/.gnupg/unxwares-helm.gpg
```

See [SECURITY.md](SECURITY.md#verifying-chart-signatures) for details.

## Versioning

Charts use calendar versioning, `year.month.number`: `2026.10.1` is the first release of October 2026, `2026.10.2`
the second one. The number restarts at 1 every month. Breaking changes are announced in the chart's
`artifacthub.io/changes` annotation and in the "Upgrading" section of its README.

## Development

```bash
# Lint and render a chart with its CI values
helm lint --strict charts/powerdns -f charts/powerdns/ci/default-values.yaml
helm template t charts/powerdns -f charts/powerdns/ci/default-values.yaml

# Validate every chart against the Kubernetes schemas (needs kubeconform)
.github/scripts/kubeconform.sh 1.31.0 1.34.0

# Regenerate values.schema.json and README.md after editing values.yaml or README.md.gotmpl
./generate-schemas.sh powerdns
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the conventions and the release process.

## Verified publisher on Artifact Hub

`artifacthub-repo.yml` holds the Artifact Hub repository ID and owners; the release workflow publishes it next to
`index.yaml`, together with the public signing key. Packages listed in its `ignore` section (the former `opencloud`
chart) stay in `index.yaml` for existing users but are hidden on Artifact Hub.

## Support

- Questions: **opensource@unxwares.com**
- Bugs and feature requests: [GitHub issues](https://github.com/UnxWares/helm/issues)
- Security vulnerabilities: **security@unxwares.com** or
  [private vulnerability reporting](https://github.com/UnxWares/helm/security/advisories/new), never a public issue
  (see [SECURITY.md](SECURITY.md))

## Contributing

Contributions are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

The charts are released under the MIT license (see [LICENSE.md](LICENSE.md)); each application keeps its own license.

## Maintainers

- David Gheghea, david.gheghea@unxwares.com
- Baptiste Gosselin, baptiste.gosselin@unxwares.com

## Links

- [UnxWares](https://unxwares.com)
- [Helm repository](https://helm.unxwares.studio)
- [Artifact Hub](https://artifacthub.io/packages/search?repo=unxwares)
