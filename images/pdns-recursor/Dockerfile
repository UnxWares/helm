# PowerDNS Recursor on Alpine, built from the release tarball (its Rust part included). Same paths (/usr/local,
# /etc/powerdns), user (pdns, uid 953), ports and startup script (Jinja2 templates of /etc/powerdns/templates.d
# rendered into /etc/powerdns/recursor.d) as powerdns/pdns-recursor-54, without the Python of the Debian image
# beyond what the startup script needs.
FROM docker.io/library/alpine:3.24 AS build

ARG VERSION=5.4.9
ARG SOURCE_SHA256=66feabd86e32d5fb38e50664e79942f64badeb7232d7dec5bc3da268b4e381ff
# dockerdata/ of the same release: the startup script and the default recursor.conf of the upstream image.
ARG DOCKERDATA_REF=rec-5.4.9
ARG STARTUP_SHA256=fc02e360c0e0d790c667329ab18ad9021d6c6b57dbc92bf2c1501a27abeb5e95
ARG CONF_SHA256=0e948ec6cf93584bb01f49fae795d743b7dc308391458e81534b2973f899e559
ARG MAKE_JOBS=""

RUN apk add --no-cache build-base boost-dev cargo curl-dev fstrm-dev libsodium-dev luajit-dev openssl-dev

WORKDIR /build
RUN set -eux; \
    wget -q -O recursor.tar.xz "https://downloads.powerdns.com/releases/pdns-recursor-${VERSION}.tar.xz"; \
    echo "${SOURCE_SHA256}  recursor.tar.xz" | sha256sum -c -; \
    tar -xJf recursor.tar.xz; \
    wget -q -O startup.py "https://raw.githubusercontent.com/PowerDNS/pdns/${DOCKERDATA_REF}/dockerdata/startup.py"; \
    echo "${STARTUP_SHA256}  startup.py" | sha256sum -c -; \
    wget -q -O recursor.conf "https://raw.githubusercontent.com/PowerDNS/pdns/${DOCKERDATA_REF}/dockerdata/recursor.conf"; \
    echo "${CONF_SHA256}  recursor.conf" | sha256sum -c -

RUN set -eux; \
    cd "pdns-recursor-${VERSION}"; \
    ./configure \
        --prefix=/usr/local \
        --sysconfdir=/etc/powerdns \
        --enable-option-checking=fatal \
        --with-lua=luajit \
        --with-libcrypto=/usr \
        --enable-dns-over-tls \
        --enable-dnstap; \
    make -j"${MAKE_JOBS:-$(nproc)}"; \
    make install DESTDIR=/out; \
    strip /out/usr/local/bin/* /out/usr/local/sbin/*

FROM docker.io/library/alpine:3.24

ARG VERSION=5.4.9
LABEL org.opencontainers.image.title="pdns-recursor" \
      org.opencontainers.image.description="PowerDNS Recursor on Alpine, rebuilt weekly by UnxWares" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="GPL-2.0-only" \
      org.opencontainers.image.vendor="UnxWares" \
      org.opencontainers.image.source="https://github.com/UnxWares/helm"

# Runtime libraries, python3 + Jinja2 for the startup script (and GNU env for its `env -S` shebang), tini as PID 1.
RUN set -eux; \
    apk upgrade --no-cache; \
    apk add --no-cache libstdc++ libgcc boost-context boost-filesystem libcurl fstrm libsodium luajit openssl python3 py3-jinja2 coreutils-env tini; \
    addgroup -S -g 953 pdns; \
    adduser -S -D -H -u 953 -G pdns -s /sbin/nologin pdns

COPY --from=build /out /
COPY --from=build /build/startup.py /usr/local/sbin/pdns_recursor-startup
COPY --from=build /build/recursor.conf /etc/powerdns/recursor.conf

RUN set -eux; \
    chmod 0755 /usr/local/sbin/pdns_recursor-startup; \
    mkdir -p /etc/powerdns/recursor.d /var/run/pdns-recursor /etc/powerdns/templates.d; \
    chown pdns:pdns /var/run/pdns-recursor /etc/powerdns/recursor.d /etc/powerdns/templates.d

USER pdns
EXPOSE 53/udp 53/tcp 8082/tcp
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/sbin/pdns_recursor-startup"]
