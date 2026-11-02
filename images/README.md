# UnxWares images

Container images used by default by the charts of this repository, published on `ghcr.io/unxwares`. They are
rebuilt from the upstream sources on current Alpine bases, so they carry far fewer known vulnerabilities than
the upstream images, and they run as a non-root user with a read-only root filesystem. Each chart can still use
the upstream images instead (see its README).

| Image | Upstream | Changes from upstream |
|-------|----------|-----------------------|
| `postgres:17.11-alpine`, `postgres:18.6-alpine` | `docker.io/library/postgres` | Alpine packages upgraded, `su-exec` instead of `gosu` (built with an old Go toolchain) |
| `taiga-back:6.10.2` | `docker.io/taigaio/taiga-back` | Alpine, non-root (uid 999), dependencies bumped for known vulnerabilities, upstream security fixes not released yet (`patches/`), Django 3.2 security fixes backported by Debian (`django-patches/`), OIDC plugin built in |
| `taiga-front:6.10.3` | `docker.io/taigaio/taiga-front` | nginx-unprivileged slim, non-root, port 8080, read-only root filesystem, OIDC plugin built in |
| `taiga-events:6.10.0` | `docker.io/taigaio/taiga-events` | Node.js 24, current dependencies, no npm, non-root, read-only root filesystem |
| `taiga-protected:6.10.1` | `docker.io/taigaio/taiga-protected` | Python 3.12 Alpine, current gunicorn and Werkzeug, non-root, read-only root filesystem |
| `pdns-auth:5.1.5` | `docker.io/powerdns/pdns-auth-51` | Alpine, built from the release tarball with the backends the chart uses (bind, gsqlite3, gpgsql, gmysql), no vim or curl |
| `pdns-recursor:5.4.9` | `docker.io/powerdns/pdns-recursor-54` | Alpine, built from the release tarball |
| `postgresql-client:18` | `docker.io/library/postgres` (its `psql`) | The PostgreSQL client only, from Alpine packages, instead of a whole server image; latest 18.x at each rebuild |
| `mysql-client:8.4` | `docker.io/library/mysql` (its `mysql`) | The MySQL client only, from the signed packages of the official MySQL repository on Oracle Linux 9 slim; latest 8.4.x at each rebuild |
| `mongosh:2.14.1` | `docker.io/library/mongo` (its `mongosh`) | The official mongosh release, checked against its SHA-256, on a distroless base; its SBOM stays in the image so that scanners see the bundled dependencies |
| `cloudreve:4.19.1` | `docker.io/cloudreve/cloudreve` | Built from the release sources with the Go module updates of `patches/` (cloudreve/cloudreve#3618), current Alpine, same thumbnail tools (libvips, FFmpeg, LibreOffice, libheif, libraw); no aria2 or supervisord, no default time zone, non-root (uid 1000) |
| `fossflow:1.0.5` | `docker.io/abrar74774/fossflow` | Built from the upstream sources (commit `2b3cee3`, release v1.0.5) with the lockfile update of `patches/` (`npm audit fix`), current Alpine, no npm, su-exec or openssl; nginx on port 8080 and the backend run as uid 1000 with a read-only root filesystem, the backend listens on 127.0.0.1 only and its CORS headers (any origin) are dropped |

The images keep the upstream ports, paths, users and environment variables (PowerDNS: the same `pdns` user,
startup script and Jinja2 templates), except `taiga-front`, which listens on 8080 instead of 80, and `cloudreve`,
whose entrypoint is the binary itself (the upstream one starts aria2 under supervisord as root). `fossflow` listens on
8080 instead of 80, runs nginx and the backend as uid 1000 instead of starting as root, and refuses
`HTTP_AUTH_USER`/`HTTP_AUTH_PASSWORD` (the upstream entrypoint cannot hash them with OpenSSL 3). The client images
(`postgresql-client`, `mysql-client`, `mongosh`) run as uid 65532 with `HOME=/tmp`, for the Jobs of
`openeverest-database-tools`.

## Tags and rebuilds

- `<version>`: the upstream version, rebuilt every Monday and Thursday on the current base image and Alpine packages. For
  `postgresql-client` and `mysql-client` it is a release series (`18`, `8.4`): each rebuild takes its latest client.
- `<version>-<YYYYMMDD>`: one immutable tag per build, to pin a build.
- `<version>-amd64`, `<version>-arm64`: the per-architecture images behind the multi-arch tag.

`.github/workflows/images.yaml` builds every image natively on amd64 and arm64 and scans it with Trivy.
The images of `cloudreve` and `openeverest-database-tools` are also built by the end-to-end tests
(`.github/workflows/e2e.yaml`), which run the chart on them in kind and check what the application does, so a change
to one of these images is tested before it is published.
Pull requests fail on a fixable CRITICAL or HIGH vulnerability, unless the image's `.trivyignore` says why it
is accepted (for `taiga-back`: the Django 3.2 vulnerabilities fixed by the Debian backports or not reachable in
Taiga, each one documented; for `mongosh`: an FTP client it only uses for proxy auto-configuration files).

## Signatures

Every published tag is signed with cosign, keyless, by the workflow:

```console
cosign verify ghcr.io/unxwares/taiga-back:6.10.2 \
  --certificate-identity 'https://github.com/UnxWares/helm/.github/workflows/images.yaml@refs/heads/main' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Sources and dependencies

- Upstream sources are downloaded from GitHub release tarballs and checked against the SHA-256 in each
  Dockerfile (`ARG *_SHA256`).
- Python dependencies are pinned with hashes in `requirements.txt`, generated from `requirements.in` with
  `images/lock.sh <image directory>` (pip-compile in the image's own base).
- Security fixes merged upstream but not released yet are applied as `patches/*.patch`, taken as is from the
  upstream commits (the file name keeps the commit hash) and applied in order; the build fails if one stops
  applying. Drop them when the upstream release that contains them is out.
- `taiga-events` uses its own `package.json` and `package-lock.json` (current versions of the upstream
  dependencies); `npm audit` reports no vulnerability.
- `fossflow` builds with the upstream lockfile updated by `npm audit fix` (`patches/0001-d94654d.patch`, from the
  `fix/vulnerable-dependencies` branch of [UnxWares/FossFLOW](https://github.com/UnxWares/FossFLOW)), and installs
  the backend dependencies from that lockfile.
- To move to a new upstream version: update `ARG VERSION` and the source checksums, regenerate the locks,
  build locally (`docker build images/<image>`), then bump the chart.
