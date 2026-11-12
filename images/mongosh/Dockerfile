# MongoDB shell (mongosh) for the openeverest-database-tools Jobs: the official release build that links the
# system OpenSSL 3, on a distroless base (glibc, OpenSSL 3, zlib, no shell), instead of a whole MongoDB server
# image. The SBOM shipped with the release stays in the image, so that scanners see the bundled dependencies.
ARG VERSION=2.14.2
FROM docker.io/library/alpine:3.24 AS download

ARG VERSION
ARG TARGETARCH
# Release archives of https://github.com/mongodb-js/mongosh/releases, signed by the Mongosh Release Signing Key
# (ED58 1728 F2A4 69C9 4D18 BB58 CEED 0419 D361 CB16); the checksums were taken from verified archives.
ARG MONGOSH_SHA256_AMD64=b63ebd577f73e0d5c6634650082f5c3db41633c00f456f240cfbc1b7917e5612
ARG MONGOSH_SHA256_ARM64=29e7cd5184e4517a60ca6e10d217079eb12e62d21d8bc52728e9a16b5cfeb9af
RUN set -eux; \
    case "$TARGETARCH" in \
        amd64) arch=x64; sha256=$MONGOSH_SHA256_AMD64 ;; \
        arm64) arch=arm64; sha256=$MONGOSH_SHA256_ARM64 ;; \
        *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    wget -q -O /tmp/mongosh.tgz \
        "https://github.com/mongodb-js/mongosh/releases/download/v${VERSION}/mongosh-${VERSION}-linux-${arch}-openssl3.tgz"; \
    echo "${sha256}  /tmp/mongosh.tgz" | sha256sum -c -; \
    mkdir /mongosh; \
    tar -xzf /tmp/mongosh.tgz -C /mongosh --strip-components=1; \
    # The automatic encryption library (mongosh_crypt_v1.so) is not used by the Jobs.
    mkdir -p /out/usr/local/bin /out/usr/share/doc/mongosh; \
    mv /mongosh/bin/mongosh /out/usr/local/bin/mongosh; \
    mv /mongosh/.sbom.json "/out/usr/share/doc/mongosh/mongosh-${VERSION}.cdx.json"; \
    mv /mongosh/LICENSE-mongosh /mongosh/THIRD_PARTY_NOTICES /out/usr/share/doc/mongosh/

FROM gcr.io/distroless/cc-debian13:nonroot

COPY --from=download /out/ /
# Any uid works: HOME points to a writable directory, the charts mount an emptyDir on /tmp.
ENV HOME=/tmp
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/mongosh"]
