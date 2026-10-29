# UnxWares images

Container images used by default by the charts of this repository, published on `ghcr.io/unxwares`. They are
rebuilt from the upstream sources on current Alpine bases, so they carry far fewer known vulnerabilities than
the upstream images, and they run as a non-root user with a read-only root filesystem. Each chart can still use
the upstream images instead (see its README).

| Image | Upstream | Changes from upstream |
|-------|----------|-----------------------|
| `postgres:17.11-alpine`, `postgres:18.6-alpine` | `docker.io/library/postgres` | Alpine packages upgraded, `su-exec` instead of `gosu` (built with an old Go toolchain) |
| `taiga-back:6.10.2` | `docker.io/taigaio/taiga-back` | Alpine, non-root (uid 999), dependencies bumped for known vulnerabilities, upstream security fixes not released yet (`patches/`), OIDC plugin built in |
| `taiga-front:6.10.3` | `docker.io/taigaio/taiga-front` | nginx-unprivileged slim, non-root, port 8080, read-only root filesystem, OIDC plugin built in |
| `taiga-events:6.10.0` | `docker.io/taigaio/taiga-events` | Node.js 24, current dependencies, no npm, non-root, read-only root filesystem |
| `taiga-protected:6.10.1` | `docker.io/taigaio/taiga-protected` | Python 3.12 Alpine, current gunicorn and Werkzeug, non-root, read-only root filesystem |
| `pdns-auth:5.1.5` | `docker.io/powerdns/pdns-auth-51` | Alpine, built from the release tarball with the backends the chart uses (bind, gsqlite3, gpgsql, gmysql), no vim or curl |
| `pdns-recursor:5.4.9` | `docker.io/powerdns/pdns-recursor-54` | Alpine, built from the release tarball |

The images keep the upstream ports, paths, users and environment variables (PowerDNS: the same `pdns` user,
startup script and Jinja2 templates), except `taiga-front`, which listens on 8080 instead of 80.

## Tags and rebuilds

- `<version>`: the upstream version, rebuilt every Monday on the current base image and Alpine packages.
- `<version>-<YYYYMMDD>`: one immutable tag per build, to pin a build.
- `<version>-amd64`, `<version>-arm64`: the per-architecture images behind the multi-arch tag.

`.github/workflows/images.yaml` builds every image natively on amd64 and arm64 and scans it with Trivy.
Pull requests fail on a fixable CRITICAL or HIGH vulnerability, unless the image's `.trivyignore` says why it
is accepted (for `taiga-back`: Django 3.2, which Taiga is pinned to).

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
- To move to a new upstream version: update `ARG VERSION` and the source checksums, regenerate the locks,
  build locally (`docker build images/<image>`), then bump the chart.
