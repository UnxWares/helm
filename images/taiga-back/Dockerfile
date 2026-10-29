# taiga-back (API and Celery workers) on Alpine, run as a non-root user, with the dependencies of the
# upstream lock except the ones bumped for known vulnerabilities (requirements.in), and the security fixes
# merged upstream but not released yet (patches/, taken as is from taiga-back main). Bundles the Slack,
# GitHub, GitLab, protected and UnxWares OIDC contribs (OIDC enabled with ENABLE_OIDC_AUTH=True). Same
# port, paths (/taiga-back, docker/entrypoint.sh, docker/async_entrypoint.sh) and environment as
# taigaio/taiga-back.
FROM docker.io/library/python:3.11-alpine3.24 AS build

ARG VERSION=6.10.2
ARG SOURCE_SHA256=a288ee6778b45937e4e41d06a856f2da2309059e82b5db93abaf903c77355d3b
# Same contrib versions as taiga-back's requirements-contribs.txt.
ARG CONTRIBS_VERSION=6.8.0
ARG SLACK_SHA256=07c112b7f9a9ce8fef0e8dec25055ae0f3aff0c971a64b3d6666719c5d641b7f
ARG GITHUB_AUTH_SHA256=c5fbecebe80a7d607870e0ad3b82084fc2530879d03bef0d44e932af14cbd070
ARG GITLAB_AUTH_SHA256=9a579508bd2488b20e5fd3927e3d96e547c2b745b07744b196cebaf4ac050d99
ARG PROTECTED_SHA256=2783d1cc7af3bb79495805d5f2a5354bc52fe0cc59632fcd7a0646b54548d0e3
ARG OIDC_COMMIT=c3e346d54d4ff08057373bf4fb8f23c426a7eed9
ARG OIDC_SHA256=a645d4531419f30b3d247d677da8e11ad6d3627fd3b2fa704efe603ef50c42b3

RUN apk add --no-cache build-base libpq-dev libffi-dev gettext libmagic cairo patch

WORKDIR /build
COPY requirements.txt .
RUN set -eux; \
    fetch() { wget -q -O "$1.tar.gz" "$2"; echo "$3  $1.tar.gz" | sha256sum -c -; mkdir "$1"; tar -xzf "$1.tar.gz" --strip-components=1 -C "$1"; }; \
    fetch back "https://github.com/taigaio/taiga-back/archive/refs/tags/${VERSION}.tar.gz" "${SOURCE_SHA256}"; \
    fetch slack "https://github.com/taigaio/taiga-contrib-slack/archive/refs/tags/${CONTRIBS_VERSION}.tar.gz" "${SLACK_SHA256}"; \
    fetch github-auth "https://github.com/taigaio/taiga-contrib-github-auth/archive/refs/tags/${CONTRIBS_VERSION}.tar.gz" "${GITHUB_AUTH_SHA256}"; \
    fetch gitlab-auth "https://github.com/taigaio/taiga-contrib-gitlab-auth/archive/refs/tags/${CONTRIBS_VERSION}.tar.gz" "${GITLAB_AUTH_SHA256}"; \
    fetch protected "https://github.com/taigaio/taiga-contrib-protected/archive/refs/tags/${CONTRIBS_VERSION}.tar.gz" "${PROTECTED_SHA256}"; \
    fetch oidc "https://github.com/UnxWares/taiga-contrib-oidc-auth/archive/${OIDC_COMMIT}.tar.gz" "${OIDC_SHA256}"; \
    python -m venv /opt/venv; \
    /opt/venv/bin/pip install --no-cache-dir --require-hashes -r requirements.txt; \
    # The contribs have no dependencies of their own beyond requirements.txt.
    /opt/venv/bin/pip install --no-cache-dir --no-deps \
        ./slack/back ./github-auth/back ./gitlab-auth/back ./protected ./oidc/back; \
    mv back /taiga-back

WORKDIR /taiga-back
ENV PATH="/opt/venv/bin:$PATH" \
    DJANGO_SETTINGS_MODULE=settings.config
COPY patches/ /build/patches/
RUN set -eux; \
    # Upstream security fixes not released yet, in commit order; the build fails if one does not apply.
    for p in /build/patches/*.patch; do patch -p1 --forward --no-backup-if-mismatch < "$p"; done; \
    cp docker/config.py settings/config.py; \
    cat /build/oidc/config.snippet.py >> settings/config.py; \
    cp /build/oidc/urls.py settings/urls.py; \
    # psd-tools 1.10 renamed PSDImage.compose() to composite(): fail the build if the call changes upstream.
    grep -q 'PSDImage.open(data).compose()' taiga/base/utils/thumbnails.py; \
    sed -i 's/PSDImage.open(data).compose()/PSDImage.open(data).composite()/' taiga/base/utils/thumbnails.py; \
    # settings.config reads SECRET_KEY from TAIGA_SECRET_KEY: a placeholder for these build steps only (it is
    # not kept in the image, the chart and docker-compose always set the real one).
    TAIGA_SECRET_KEY=build-only python manage.py compilemessages; \
    TAIGA_SECRET_KEY=build-only python manage.py collectstatic --no-input; \
    /opt/venv/bin/pip uninstall -y pip setuptools

FROM docker.io/library/python:3.11-alpine3.24

ARG VERSION=6.10.2
LABEL org.opencontainers.image.title="taiga-back" \
      org.opencontainers.image.description="Taiga back on Alpine, non-root, with the OIDC plugin, rebuilt weekly by UnxWares" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="MPL-2.0" \
      org.opencontainers.image.vendor="UnxWares" \
      org.opencontainers.image.source="https://github.com/UnxWares/helm"

# Runtime libraries: libpq (psycopg2), libmagic (python-magic), cairo (CairoSVG thumbnails). pip, setuptools
# and wheel of the base image are not needed at runtime.
RUN set -eux; \
    apk upgrade --no-cache; \
    apk add --no-cache libpq libmagic cairo; \
    rm -rf /usr/local/lib/python3.11/site-packages/pip /usr/local/lib/python3.11/site-packages/pip-* \
           /usr/local/lib/python3.11/site-packages/setuptools /usr/local/lib/python3.11/site-packages/setuptools-* \
           /usr/local/lib/python3.11/site-packages/wheel /usr/local/lib/python3.11/site-packages/wheel-* \
           /usr/local/lib/python3.11/site-packages/pkg_resources /usr/local/lib/python3.11/site-packages/_distutils_hack \
           /usr/local/lib/python3.11/site-packages/distutils-precedence.pth /usr/local/bin/pip*; \
    mkdir -p /taiga-back/media/exports; \
    chown -R 999:999 /taiga-back/media

COPY --from=build /opt/venv /opt/venv
COPY --from=build /taiga-back /taiga-back
COPY entrypoint.sh /taiga-back/docker/entrypoint.sh
COPY async_entrypoint.sh /taiga-back/docker/async_entrypoint.sh

ENV PATH="/opt/venv/bin:$PATH" \
    DJANGO_SETTINGS_MODULE=settings.config \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONFAULTHANDLER=1
WORKDIR /taiga-back
USER 999:999
EXPOSE 8000
ENTRYPOINT ["./docker/entrypoint.sh"]
