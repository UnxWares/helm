# PostgreSQL 18: the official Alpine image with every Alpine package upgraded at build time, and su-exec
# instead of gosu. The entrypoint only uses gosu to drop root privileges (the charts run PostgreSQL as a
# non-root user), and the gosu binary is built with an old Go toolchain that carries known vulnerabilities.
ARG VERSION=18.6
FROM docker.io/library/postgres:${VERSION}-alpine3.24

RUN set -eux; \
    apk upgrade --no-cache; \
    apk add --no-cache su-exec; \
    # Remove the file (rather than overwrite it) so that image scanners see it gone.
    rm /usr/local/bin/gosu; \
    ln -s /sbin/su-exec /usr/bin/gosu
