# ISC BIND 9 (named and its tools) on Alpine, built from the release tarball, checked against its SHA-256 and against
# the OpenPGP signature of an ISC code-signing key (isc-keyblock.asc, the keys of https://www.isc.org/pgpkey/). Same
# base, build options, paths (/usr, /etc/bind, /var/cache/bind, /var/lib/bind, /run/named), ports and user (bind,
# uid 53) as the official internetsystemsconsortium/bind9 image (https://github.com/isc-projects/bind9-docker, branch
# v9.20), so that a named.conf that loads there loads here. The official image is rebuilt once per BIND release; this
# one twice a week, on the current Alpine packages. It runs as bind from the start (no -u, no root), logs to stderr
# (-g) and leaves out procps, the headers and the static libraries.
FROM docker.io/library/alpine:3.24 AS build

ARG VERSION=9.20.30
ARG SOURCE_SHA256=9e1443a40a72a30272cbc3196d020a6b2e26937111c83e59e101e82e1e3b4fef
ARG MAKE_JOBS=""

RUN apk add --no-cache build-base pkgconf gnupg fstrm-dev jemalloc-dev json-c-dev krb5-dev libcap-dev libidn2-dev \
        libmaxminddb-dev libuv-dev libxml2-dev lmdb-dev nghttp2-dev openssl-dev protobuf-c-dev userspace-rcu-dev \
        zlib-dev

WORKDIR /build
COPY isc-keyblock.asc /build/isc-keyblock.asc
RUN set -eux; \
    wget -q -O bind.tar.xz "https://downloads.isc.org/isc/bind9/${VERSION}/bind-${VERSION}.tar.xz"; \
    wget -q -O bind.tar.xz.asc "https://downloads.isc.org/isc/bind9/${VERSION}/bind-${VERSION}.tar.xz.asc"; \
    echo "${SOURCE_SHA256}  bind.tar.xz" | sha256sum -c -; \
    export GNUPGHOME=/build/gnupg; \
    mkdir -m 0700 "$GNUPGHOME"; \
    gpg --batch --quiet --import isc-keyblock.asc; \
    gpg --batch --verify bind.tar.xz.asc bind.tar.xz; \
    tar -xJf bind.tar.xz

# The options of the official image, each feature required (=yes): the build fails instead of leaving one out.
RUN set -eux; \
    cd "bind-${VERSION}"; \
    ./configure \
        --prefix=/usr \
        --sysconfdir=/etc/bind \
        --localstatedir=/ \
        --enable-option-checking=fatal \
        --enable-shared \
        --disable-static \
        --enable-dnstap \
        --with-gssapi=yes \
        --with-jemalloc=yes \
        --with-json-c=yes \
        --with-libidn2=yes \
        --with-libnghttp2=yes \
        --with-libxml2=yes \
        --with-lmdb=yes \
        --with-maxminddb=yes \
        --with-zlib=yes \
        --with-readline=no; \
    make -j"${MAKE_JOBS:-$(nproc)}"; \
    make install DESTDIR=/out

# Only the programs, the shared libraries and the named plugins (filter-a, filter-aaaa), stripped.
RUN set -eux; \
    mkdir -p /rootfs/usr/lib/bind; \
    cp -a /out/usr/bin /out/usr/sbin /rootfs/usr/; \
    cp -a /out/usr/lib/*-"${VERSION}".so /rootfs/usr/lib/; \
    cp -a /out/usr/lib/bind/*.so /rootfs/usr/lib/bind/; \
    strip /rootfs/usr/bin/* /rootfs/usr/sbin/* /rootfs/usr/lib/*.so /rootfs/usr/lib/bind/*.so

FROM docker.io/library/alpine:3.24

ARG VERSION=9.20.30
LABEL org.opencontainers.image.title="bind9" \
      org.opencontainers.image.description="ISC BIND 9 on Alpine, built from the signed release tarball, rebuilt twice a week by UnxWares" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="MPL-2.0" \
      org.opencontainers.image.vendor="UnxWares" \
      org.opencontainers.image.source="https://github.com/UnxWares/helm"

# Runtime libraries of the build options above (OpenSSL and zlib come with the base), tzdata for TZ.
RUN set -eux; \
    apk upgrade --no-cache; \
    apk add --no-cache fstrm jemalloc json-c krb5-libs libcap2 libidn2 libmaxminddb-libs libuv libxml2 lmdb \
        nghttp2-libs protobuf-c tzdata userspace-rcu; \
    addgroup -S -g 53 bind; \
    adduser -S -D -H -u 53 -G bind -h /var/cache/bind -s /sbin/nologin bind

COPY --from=build /rootfs /
COPY named.conf /etc/bind/named.conf

# /etc/bind is read-only for named; it writes in its working directory (/var/cache/bind), /var/lib/bind (dynamic and
# secondary zones, journals, keys) and /run/named (pid file, session key).
RUN set -eux; \
    mkdir -p /var/cache/bind /var/lib/bind /var/log/bind /run/named; \
    chown root:bind /etc/bind /etc/bind/named.conf; \
    chmod 0755 /etc/bind; \
    chmod 0644 /etc/bind/named.conf; \
    chown bind:bind /var/cache/bind /var/lib/bind /var/log/bind /run/named; \
    named -V; \
    named -v | grep -F "BIND ${VERSION} "; \
    named-checkconf /etc/bind/named.conf; \
    dig -v; \
    rndc 2>&1 | grep -F "Version: ${VERSION}"

USER 53:53
EXPOSE 53/udp 53/tcp 953/tcp 853/tcp 443/tcp
ENTRYPOINT ["/usr/sbin/named"]
CMD ["-g"]
