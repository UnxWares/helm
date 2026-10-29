# taiga-protected (signed URLs for attachments) on Alpine, run as a non-root user with current
# gunicorn, Werkzeug and python-dotenv releases. Same port, entrypoint arguments and environment
# as taigaio/taiga-protected.
FROM docker.io/library/python:3.12-alpine3.24 AS build

ARG VERSION=6.10.1
ARG SOURCE_SHA256=0ba648786f37a16c910a3ecf8e3c23f52618116bb9132aad32137362e7eced44

WORKDIR /build
COPY requirements.txt .
RUN set -eux; \
    wget -q -O source.tar.gz "https://github.com/taigaio/taiga-protected/archive/refs/tags/${VERSION}.tar.gz"; \
    echo "${SOURCE_SHA256}  source.tar.gz" | sha256sum -c -; \
    mkdir src; \
    tar -xzf source.tar.gz --strip-components=1 -C src; \
    mkdir /taiga-protected; \
    cp -r src/server.py src/_vendor /taiga-protected/; \
    python -m venv /opt/venv; \
    /opt/venv/bin/pip install --no-cache-dir --require-hashes --only-binary :all: -r requirements.txt; \
    /opt/venv/bin/pip uninstall -y pip

FROM docker.io/library/python:3.12-alpine3.24

ARG VERSION=6.10.1
LABEL org.opencontainers.image.title="taiga-protected" \
      org.opencontainers.image.description="Taiga protected on Alpine, non-root, rebuilt weekly by UnxWares" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="MPL-2.0" \
      org.opencontainers.image.vendor="UnxWares" \
      org.opencontainers.image.source="https://github.com/UnxWares/helm"

# pip is not needed at runtime.
RUN set -eux; \
    apk upgrade --no-cache; \
    rm -rf /usr/local/lib/python3.*/site-packages/pip /usr/local/lib/python3.*/site-packages/pip-* /usr/local/bin/pip*

COPY --from=build /opt/venv /opt/venv
COPY --from=build /taiga-protected /taiga-protected

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONFAULTHANDLER=1
WORKDIR /taiga-protected
USER 999:999
EXPOSE 8003
ENTRYPOINT ["gunicorn", "server:app", \
    "--name", "taiga_protected", \
    "--bind", "0.0.0.0:8003", \
    "--workers", "4", \
    "--worker-tmp-dir", "/dev/shm", \
    "--max-requests", "3600", \
    "--max-requests-jitter", "360", \
    "--timeout", "60", \
    "--log-level=info", \
    "--access-logfile", "-"]
