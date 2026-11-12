<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://helm.unxwares.studio/assets/logo-dark.svg">
    <img src="https://helm.unxwares.studio/assets/logo.svg" alt="UnxWares" width="400">
  </picture>
</div>

# <div align="center">UnxWares Helm Charts</div>

<div align="center">

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/unxwares)](https://artifacthub.io/packages/search?repo=unxwares)
[![Release Charts](https://github.com/UnxWares/helm/actions/workflows/release.yaml/badge.svg)](https://github.com/UnxWares/helm/actions/workflows/release.yaml)
[![End-to-end tests](https://github.com/UnxWares/helm/actions/workflows/e2e.yaml/badge.svg)](https://github.com/UnxWares/helm/actions/workflows/e2e.yaml)
[![CVE watch](https://github.com/UnxWares/helm/actions/workflows/cve-watch.yaml/badge.svg)](https://github.com/UnxWares/helm/issues?q=is%3Aissue+is%3Aopen+label%3Acve-watch)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.md)
[![UWOSC: maintained](https://helm.unxwares.studio/assets/uwosc/mini-maintained.svg)](#open-source)

[Charts](#available-charts) • [Images](#images) • [Testing](#how-the-charts-are-tested) • [Installation](#installation) • [Signatures](#verifying-signatures) • [Contributing](#contributing) • [Open source](#open-source) • [Support](#support)

</div>

---

Helm charts we run ourselves, maintained by UnxWares, a small independent team in Caen, France. Every chart follows
the same rules:

- **Current, scanned images**: pinned versions, scanned every 6 hours with Trivy (the
  [CVE watch](https://github.com/UnxWares/helm/issues?q=is%3Aissue+is%3Aopen+label%3Acve-watch) issue). Where the
  upstream images lag behind, the charts default to our own rebuilds (see [Images](#images)); releases that bring
  security fixes are flagged `containsSecurityUpdates` on Artifact Hub.
- **No default passwords**: secrets are generated once and kept across upgrades, or read from your own Secret, and
  reach containers through `secretKeyRef` only.
- **Hardened by default**: non-root wherever the image allows it, read-only root filesystem, capabilities dropped,
  seccomp `RuntimeDefault`, no service account token unless the workload talks to the Kubernetes API. Each README
  says where a chart cannot meet this and why.
- **Tested**: every pull request lints, validates and installs the charts, and the charts with an end-to-end test
  drive the application and check its answers (see [How the charts are tested](#how-the-charts-are-tested)).
- **Documented**: a values schema (`values.schema.json`) and a README with the architecture, configuration by topic,
  security notes, troubleshooting and upgrade notes, generated from the annotated `values.yaml`.
- **Signed packages** (Helm provenance files).

## Available charts

| Chart | Application | Default images | Tested in CI |
|-------|-------------|----------------|--------------|
| [bind9](charts/bind9) | ISC BIND 9.20 | ISC (named), UnxWares (exporter) | Install (UnxWares and upstream exporter), `helm test` (DNS query), end to end |
| [cloudreve](charts/cloudreve) | Cloudreve 4.19 | UnxWares | Install (UnxWares and upstream images), `helm test`, end to end |
| [excalidash](charts/excalidash) | ExcaliDash 0.6 | Upstream | Install, `helm test` (health endpoint), end to end |
| [fossflow](charts/fossflow) | FossFLOW 1.0 | UnxWares | Install (UnxWares and upstream images), `helm test`, end to end |
| [kener](charts/kener) | Kener 4.2 | Upstream (Kener, Valkey) | Install, `helm test` (strict health check), end to end |
| [laravel-generic](charts/laravel-generic) | Laravel 12 | Your image, nginx-unprivileged | `helm test`, end to end (a Laravel test application built in CI, FrankenPHP and PHP-FPM) |
| [openeverest-database-tools](charts/openeverest-database-tools) | OpenEverest 1.17 | UnxWares (database clients), kubectl | End to end |
| [powerdns](charts/powerdns) | PowerDNS Auth 5.1 / Recursor 5.4 | UnxWares | Install (UnxWares and upstream images), `helm test` (API), end to end |
| [taiga](charts/taiga) | Taiga 6.10 | UnxWares | Install (UnxWares and upstream images), `helm test`, end to end |

What each chart deploys:

- **bind9**: authoritative DNS server, with an optional Prometheus exporter.
- **cloudreve**: self-hosted file management and sharing (SQLite, PostgreSQL, MySQL, Redis).
- **excalidash**: dashboard and organizer for Excalidraw drawings, with live collaboration and OIDC.
- **fossflow**: isometric infrastructure diagrams, with server-side storage.
- **kener**: status page with a bundled Valkey, SQLite or external PostgreSQL/MySQL.
- **laravel-generic**: your own Laravel image, with FrankenPHP or PHP-FPM + nginx, queue workers, scheduler and
  migrations.
- **openeverest-database-tools**: Jobs that create databases, users and grants and run init scripts on OpenEverest
  PostgreSQL, MySQL and MongoDB clusters.
- **powerdns**: authoritative DNS with its REST API (SQLite, PostgreSQL, MySQL) and an optional recursor.
- **taiga**: agile project management: backend, workers, events, front, bundled PostgreSQL and RabbitMQ.

Each chart README covers the architecture, every value, examples, security, troubleshooting and the upgrade notes
between releases.

## Images

Where the upstream images lag behind (old base layers, outdated dependencies, tools the chart never runs), the charts
default to our own builds, published on `ghcr.io/unxwares`:

| Image | Used by | What differs from upstream |
|-------|---------|----------------------------|
| `cloudreve` | cloudreve | Built from the release sources with current Go modules, current Alpine, no aria2/supervisord |
| `fossflow` | fossflow | Built from the upstream sources with updated npm dependencies, current Alpine, non-root, read-only root filesystem, backend on 127.0.0.1 only |
| `pdns-auth`, `pdns-recursor` | powerdns | Alpine, built from the release tarballs with the backends the chart uses |
| `postgres` 17, 18 | taiga | Alpine packages upgraded, `su-exec` instead of `gosu` |
| `taiga-back`, `taiga-front`, `taiga-events`, `taiga-protected` | taiga | Current dependencies, upstream security fixes not released yet, non-root |
| `postgresql-client`, `mysql-client`, `mongosh` | openeverest-database-tools, powerdns (schema init) | The database clients alone instead of whole server images |
| `bind-exporter` | bind9 | Built from the master sources with Go 1.27 and current `golang.org/x` modules, distroless, non-root |

They are rebuilt every Monday and Thursday on current bases, and sooner when the CVE watch finds a critical or high
vulnerability that a rebuild fixes; they are scanned with Trivy and signed with cosign, and each chart can still use
the upstream images. Sources, differences and the signature check are in [images/](images/README.md).

## How the charts are tested

| When | What |
|------|------|
| Every pull request | `helm lint --strict` with Helm 3 and 4 on each chart's default and `ci/*-values.yaml` values, kubeconform on several Kubernetes versions, chart-testing (`ct lint`, then `ct install` on kind, which runs each chart's `helm test`), Artifact Hub lint, a check that the READMEs and schemas are generated |
| Pull requests touching a chart with an end-to-end test, every push to main, every Tuesday | [`e2e.yaml`](.github/workflows/e2e.yaml): the images of the commit are built and loaded into kind, the chart is installed next to real dependencies, and a script drives the application and checks its answers |
| Pull requests touching `images/` | Each image is built for amd64 and arm64 and fails on a fixable critical or high vulnerability that is not documented |
| Every 6 hours, and after each image rebuild | The CVE watch scans every image the charts can deploy, and the official image each UnxWares image replaces |
| When the CVE watch finds a critical or high vulnerability that a rebuild fixes in one of our images | The watch starts the image workflow instead of waiting for the next scheduled rebuild: for OS packages and the Go standard library of the build images, not for the dependencies pinned in `images/` (they need a pull request) nor for what an image's `.trivyignore` accepts. Never from the watch that follows a rebuild, and not within 20 hours of the previous image workflow run on main; the CVE watch issue says which images and vulnerabilities |

The end-to-end tests:

- **openeverest-database-tools**: real PostgreSQL, MySQL and MongoDB servers and a stand-in for the operator; the
  Jobs run, then the application users log in, and their rights, missing rights and init scripts are checked, before
  and after a password rotation.
- **cloudreve**: the first account signs up and is administrator, logs in, uploads a file, finds it in the listing,
  downloads the same content and gets a thumbnail generated for an uploaded image.
- **taiga**: a superuser created with `manage.py` logs in through the gateway, creates a project and a user story
  and reads them back, receives the change on the events websocket, uploads an attachment and downloads it through
  its signed URL (refused without it); the periodic tasks are sent once with two workers; a pod outside the release
  only reaches the gateway (NetworkPolicies); a reinstall starts on the kept Secret and volumes.
- **kener**: the first account signs up (a second one is refused) and logs in, creates an API key, creates a monitor
  and a status page through the REST API; the monitor runs and the status page shows it operational. Custom monitor
  eval code runs in the Kener sandbox inside the hardened pod, and evals that read the environment or loop forever
  are stopped without Kener restarting. Valkey refuses commands without its password and other pods
  (NetworkPolicies); after a reinstall the account and API key still work.
- **excalidash**: authentication is turned on, the first administrator registers with the setup code of the logs
  and logs in, creates a drawing, finds it in the listing, exports it and gets the export accepted by the import
  check; cookies are `Secure` behind TLS, the backend refuses other pods, and a reinstall keeps the session and the
  drawing.
- **fossflow**: in a namespace that enforces the `restricted` Pod Security Standard, a diagram is created, listed,
  read back, updated and still there after the pod is replaced; the browser-only mode serves the app; from other
  pods, the backend port cannot be reached and the NetworkPolicy keeps out the pods it does not allow.
- **bind9**: in a namespace that enforces the `restricted` Pod Security Standard, the zones of the values answer their
  records over UDP and TCP from another pod, other zones and transfers are refused, named runs as uid 53 without
  capabilities, the exporter reports `bind_up 1`, and the NetworkPolicy keeps the metrics from other pods.
- **powerdns**: SQLite with the recursor, PostgreSQL over verified TLS and MySQL; the API refuses wrong keys, creates
  a zone and adds a record, the authoritative server and the recursor answer them from another pod, and they are
  still answered after a restart.
- **laravel-generic**: a Laravel 13 test application built in CI, in a namespace that enforces the `restricted` Pod
  Security Standard: FrankenPHP with SQLite on the persistent volume, and PHP-FPM behind the nginx sidecar with
  PostgreSQL. Laravel answers through the expected runtime as uid 33 on a read-only root filesystem, every pod uses
  the generated APP_KEY, the migrations ran in the init container or the hook Job, a note is written to the database
  and read back decrypted, the session and the cache keep their values, a queued job runs in the queue worker and
  writes files that the web pod serves, the scheduler runs every minute, and other pods cannot reach PHP-FPM
  (NetworkPolicy); a reinstall keeps the APP_KEY, the session, the files and the data.

Unit tests ([helm-unittest](https://github.com/helm-unittest/helm-unittest) suites in `charts/<chart>/tests`, run by
[`unit.yaml`](.github/workflows/unit.yaml)) render the templates without a cluster and check the security contexts,
the image selection, the required values, the Secrets and the probes; every chart has them. The latest result of
each kind, per chart, with the CVE counts of the images, is published at <https://helm.unxwares.studio> (raw data:
[status.json](https://helm.unxwares.studio/status.json)), rebuilt by [`site.yaml`](.github/workflows/site.yaml).

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

# Run an end-to-end test locally in kind (rootless podman works with KIND_EXPERIMENTAL_PROVIDER=podman)
kind create cluster
docker build --tag local/cloudreve:e2e images/cloudreve
kind load docker-image local/cloudreve:e2e
helm install cloudreve charts/cloudreve --namespace cloudreve --create-namespace \
  --set image.repository=local/cloudreve --set image.tag=e2e --wait
.github/scripts/cloudreve-e2e.sh cloudreve cloudreve
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the conventions and the release process.

## Verified publisher on Artifact Hub

`artifacthub-repo.yml` holds the Artifact Hub repository ID and owners; the release workflow publishes it next to
`index.yaml`, together with the public signing key. Packages listed in its `ignore` section (the former `opencloud`
chart) stay in `index.yaml` for existing users but are hidden on Artifact Hub.

## Open source

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://helm.unxwares.studio/assets/uwosc/badge-maintained-dark.svg">
  <img src="https://helm.unxwares.studio/assets/uwosc/badge-maintained.svg" alt="UnxWares Open Source &amp; Community: supported and maintained by UnxWares" width="308" height="44">
</picture>

These charts are part of **UnxWares Open Source & Community** (UWOSC), the open source work that UnxWares supports and
maintains. *Maintained* means UnxWares answers for them: we keep them current, test every change and fix what breaks.
Every chart README carries the badge.

## Support

- Known vulnerabilities of the images: the [CVE watch](https://github.com/UnxWares/helm/issues?q=is%3Aissue+is%3Aopen+label%3Acve-watch) issue
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
