# taiga-events (websockets) on the current Node.js LTS and Alpine, with current dependencies
# (package.json: amqplib 0.10, jsonwebtoken 9, ws 8...), no npm in the final image, run as a
# non-root user. Same ports and environment as taigaio/taiga-events.
FROM docker.io/library/node:24-alpine3.24 AS build

ARG VERSION=6.10.0
ARG SOURCE_SHA256=d0fbb8cb70f1566982e21e611433dcdeb3b8212f2268fee2d3419b517b2e3d23

WORKDIR /build
COPY package.json package-lock.json ./
RUN set -eux; \
    wget -q -O source.tar.gz "https://github.com/taigaio/taiga-events/archive/refs/tags/${VERSION}.tar.gz"; \
    echo "${SOURCE_SHA256}  source.tar.gz" | sha256sum -c -; \
    mkdir src; \
    tar -xzf source.tar.gz --strip-components=1 -C src; \
    mkdir /taiga-events; \
    cp -r src/src package.json package-lock.json /taiga-events/; \
    cd /taiga-events; \
    npm ci --omit=dev --ignore-scripts --no-audit --no-fund

FROM docker.io/library/node:24-alpine3.24

ARG VERSION=6.10.0
LABEL org.opencontainers.image.title="taiga-events" \
      org.opencontainers.image.description="Taiga events on Alpine, non-root, rebuilt weekly by UnxWares" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="MPL-2.0" \
      org.opencontainers.image.vendor="UnxWares" \
      org.opencontainers.image.source="https://github.com/UnxWares/helm"

# npm, npx, corepack and Yarn are not needed at runtime. tini forwards SIGTERM to node, which does not
# handle signals as PID 1 (pods would otherwise wait for the whole termination grace period).
RUN set -eux; \
    apk upgrade --no-cache; \
    apk add --no-cache tini; \
    rm -rf /usr/local/lib/node_modules /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
           /usr/local/bin/yarn /usr/local/bin/yarnpkg /opt/yarn-*

COPY --from=build /taiga-events /taiga-events
COPY entrypoint.sh /usr/local/bin/taiga-events-entrypoint

WORKDIR /taiga-events
USER 999:999
EXPOSE 8888 3023
ENTRYPOINT ["/sbin/tini", "--", "taiga-events-entrypoint"]
