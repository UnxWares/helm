# MySQL client (mysql) for the openeverest-database-tools Jobs: Oracle Linux 9 slim, as the official image, with
# the client packages of the official MySQL repository only, instead of a whole MySQL server image. The MariaDB
# client of other distributions does not take the MySQL options the Jobs use (ssl-mode). VERSION is the MySQL
# release series: every weekly rebuild takes its latest client.
ARG VERSION=8.4
FROM docker.io/library/oraclelinux:9-slim

ARG VERSION
# MySQL Release Engineering <mysql-build@oss.oracle.com>, BCA4 3417 C3B4 85DD 128E C6D4 B7B3 B788 A8D3 785C
# (https://dev.mysql.com/doc/refman/8.4/en/checking-gpg-signature.html): every package is checked against it.
COPY RPM-GPG-KEY-mysql /etc/pki/rpm-gpg/RPM-GPG-KEY-mysql
RUN set -eux; \
    { \
        echo "[mysql${VERSION}-community]"; \
        echo "name=MySQL ${VERSION} Community"; \
        echo "baseurl=https://repo.mysql.com/yum/mysql-${VERSION}-community/el/9/\$basearch/"; \
        echo 'enabled=1'; \
        echo 'gpgcheck=1'; \
        echo 'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-mysql'; \
        echo 'module_hotfixes=true'; \
    } > /etc/yum.repos.d/mysql-community.repo; \
    microdnf upgrade -y --nodocs; \
    microdnf install -y --nodocs --setopt=install_weak_deps=0 mysql-community-client; \
    microdnf clean all; \
    mysql --version | grep -F " ${VERSION}."

# Any uid works: HOME points to a writable directory, the charts mount an emptyDir on /tmp.
ENV HOME=/tmp
USER 65532:65532
