# Prometheus bind_exporter built from its sources: the master branch (its last release, v0.8.0 of November 2024,
# was built with an old Go toolchain and old dependencies), with the golang.org/x module updates of patches/
# (0001 is proposed upstream in prometheus-community/bind_exporter#301; 0002 moves golang.org/x/crypto to v0.59.0,
# which removes the deprecated openpgp packages of GO-2026-5932), with a current Go toolchain. A static binary on a
# distroless base, with the same path, flags, port (9119) and user (nobody, uid 65534) as the upstream image.
# VERSION is `git describe --tags` of the commit: 62 commits after v0.8.0.
ARG VERSION=0.8.0-62-gbafd56f

FROM docker.io/library/golang:1.27-alpine3.24 AS build
ARG VERSION
# The master commit VERSION describes, and the SHA-256 of its GitHub archive.
ARG COMMIT=bafd56fcd1137c77e0e406acfeaadc03014200d7
ARG SOURCE_SHA256=b5e2be79488a612b9efbb93096581de9917d593f8a83b8562a6dc6e4e7ae0bee
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
WORKDIR /src
COPY patches/ /patches/
RUN set -eux; \
    case "$VERSION" in *-g"$(echo "$COMMIT" | cut -c1-7)") ;; *) echo "VERSION does not describe COMMIT" >&2; exit 1 ;; esac; \
    apk add --no-cache patch; \
    wget -q -O /tmp/bind_exporter.tar.gz "https://github.com/prometheus-community/bind_exporter/archive/${COMMIT}.tar.gz"; \
    echo "${SOURCE_SHA256}  /tmp/bind_exporter.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/bind_exporter.tar.gz --strip-components=1; \
    for p in /patches/*.patch; do patch -p1 --forward < "$p"; done
RUN set -eux; \
    go build -trimpath -o /bind_exporter -ldflags "-s -w \
        -X github.com/prometheus/common/version.Version=${VERSION} \
        -X github.com/prometheus/common/version.Revision=${COMMIT} \
        -X github.com/prometheus/common/version.Branch=master \
        -X github.com/prometheus/common/version.BuildUser=unxwares \
        -X github.com/prometheus/common/version.BuildDate=$(date -u +%Y%m%d-%H:%M:%S)" .; \
    go version -m /bind_exporter | head -1; \
    /bind_exporter --version

FROM gcr.io/distroless/static-debian13

ARG VERSION
LABEL org.opencontainers.image.title="bind-exporter" \
      org.opencontainers.image.description="Prometheus bind_exporter built from its sources, rebuilt weekly by UnxWares" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="UnxWares" \
      org.opencontainers.image.source="https://github.com/UnxWares/helm"

COPY --from=build /bind_exporter /bin/bind_exporter
USER 65534:65534
EXPOSE 9119
ENTRYPOINT ["/bin/bind_exporter"]
