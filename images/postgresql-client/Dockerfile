# PostgreSQL client (psql) for the openeverest-database-tools Jobs: Alpine with the PostgreSQL client package
# only, instead of a whole PostgreSQL server image. VERSION is the PostgreSQL major version: every weekly rebuild
# takes the latest minor release Alpine ships for it.
ARG VERSION=18
FROM docker.io/library/alpine:3.24

ARG VERSION
RUN set -eux; \
    apk upgrade --no-cache; \
    apk add --no-cache "postgresql${VERSION}-client"; \
    psql --version | grep -F " ${VERSION}."

# Any uid works: HOME points to a writable directory, the charts mount an emptyDir on /tmp.
ENV HOME=/tmp
USER 65532:65532
