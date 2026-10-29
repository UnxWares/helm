# PowerDNS Authoritative Server on Alpine, built from the release tarball, with the bind, gsqlite3, gpgsql and
# gmysql backends. Same paths (/usr/local, /etc/powerdns), user (pdns, uid 953), ports, startup script (Jinja2
# templates of /etc/powerdns/templates.d rendered into /etc/powerdns/pdns.d) and SQLite schema as
# powerdns/pdns-auth-51, without vim, curl or the unused backends.
FROM docker.io/library/alpine:3.24 AS build

ARG VERSION=5.1.5
ARG SOURCE_SHA256=7b670653ccd72be30d973bbdd349c4505beda1b87b842af702a341fa6837f8aa
# dockerdata/ of the same release: the startup script and the default pdns.conf of the upstream image.
ARG DOCKERDATA_REF=auth-5.1.5
ARG STARTUP_SHA256=17869813e5b375f9732c65fd3941d3101be1641b4837970486230c7951ad8e04
ARG CONF_SHA256=db9af47999b764fa516c72ae38ffc6795b4249a0e7f7374033d0f7e479a6c0ec
ARG MAKE_JOBS=""

RUN apk add --no-cache build-base boost-dev curl-dev libpq-dev libsodium-dev luajit-dev \
        mariadb-connector-c-dev openssl-dev sqlite-dev

WORKDIR /build
RUN set -eux; \
    wget -q -O pdns.tar.bz2 "https://downloads.powerdns.com/releases/pdns-${VERSION}.tar.bz2"; \
    echo "${SOURCE_SHA256}  pdns.tar.bz2" | sha256sum -c -; \
    tar -xjf pdns.tar.bz2; \
    wget -q -O startup.py "https://raw.githubusercontent.com/PowerDNS/pdns/${DOCKERDATA_REF}/dockerdata/startup.py"; \
    echo "${STARTUP_SHA256}  startup.py" | sha256sum -c -; \
    wget -q -O pdns.conf "https://raw.githubusercontent.com/PowerDNS/pdns/${DOCKERDATA_REF}/dockerdata/pdns.conf"; \
    echo "${CONF_SHA256}  pdns.conf" | sha256sum -c -

RUN set -eux; \
    cd "pdns-${VERSION}"; \
    ./configure \
        --prefix=/usr/local \
        --sysconfdir=/etc/powerdns \
        --enable-option-checking=fatal \
        --with-lua=luajit \
        --with-libsodium \
        --with-modules='' \
        --with-dynmodules='bind gmysql gpgsql gsqlite3' \
        --enable-tools \
        --disable-static; \
    make -j"${MAKE_JOBS:-$(nproc)}"; \
    make install DESTDIR=/out; \
    strip /out/usr/local/bin/* /out/usr/local/sbin/* /out/usr/local/lib/pdns/*.so

FROM docker.io/library/alpine:3.24

ARG VERSION=5.1.5
LABEL org.opencontainers.image.title="pdns-auth" \
      org.opencontainers.image.description="PowerDNS Authoritative Server on Alpine, rebuilt weekly by UnxWares" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="GPL-2.0-only" \
      org.opencontainers.image.vendor="UnxWares" \
      org.opencontainers.image.source="https://github.com/UnxWares/helm"

# Runtime libraries of the binaries and backends, python3 + Jinja2 for the startup script (and GNU env for its
# `env -S` shebang), sqlite3 for the schema of the gsqlite3 backend, tini as PID 1.
RUN set -eux; \
    apk upgrade --no-cache; \
    apk add --no-cache libstdc++ libgcc boost-program_options libcurl libpq libsodium luajit mariadb-connector-c \
        openssl sqlite-libs sqlite python3 py3-jinja2 coreutils-env tini; \
    addgroup -S -g 953 pdns; \
    adduser -S -D -H -u 953 -G pdns -s /sbin/nologin pdns

COPY --from=build /out /
COPY --from=build /build/startup.py /usr/local/sbin/pdns_server-startup
COPY --from=build /build/pdns.conf /etc/powerdns/pdns.conf

RUN set -eux; \
    chmod 0755 /usr/local/sbin/pdns_server-startup; \
    mkdir -p /etc/powerdns/pdns.d /var/run/pdns /var/lib/powerdns /etc/powerdns/templates.d; \
    chown pdns:pdns /var/run/pdns /var/lib/powerdns /etc/powerdns/pdns.d /etc/powerdns/templates.d

USER pdns
RUN sqlite3 /var/lib/powerdns/pdns.sqlite3 < /usr/local/share/doc/pdns/schema.sqlite3.sql

EXPOSE 53/udp 53/tcp 8081/tcp
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/sbin/pdns_server-startup"]
