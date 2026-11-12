# FossFLOW built from the upstream sources, with patches/ (the backend without its unused uuid dependency), on a
# current Alpine. One container, run as the non-root `node` user (uid 1000) with a read-only root filesystem: nginx
# serves the web app on port 8080 and proxies /api/ to the storage backend, which only listens on 127.0.0.1:3001.
# Same environment variables as abrar74774/fossflow (ENABLE_SERVER_STORAGE, STORAGE_PATH), no su-exec, openssl or npm
# at runtime.
ARG VERSION=1.0.6

# The commit of the upstream image abrar74774/fossflow:master-b06baad (release v1.0.6: the release commit after it
# only bumps the version numbers). Its lockfile has the dependency updates of Abrar74774/FossFLOW#24, applied here as
# a patch up to v1.0.5.
FROM docker.io/library/node:24-alpine3.24 AS build
ARG FOSSFLOW_COMMIT=b06baade1c48e3eb222cbd130b201051b13041a6
ARG FOSSFLOW_SHA256=45230fea480b115a1a391805922cc407915dabba9cfba81d62e8f499224cf61f
WORKDIR /src
COPY patches/ /patches/
RUN set -eux; \
    apk add --no-cache patch; \
    wget -q -O /tmp/fossflow.tar.gz "https://github.com/Abrar74774/FossFLOW/archive/${FOSSFLOW_COMMIT}.tar.gz"; \
    echo "${FOSSFLOW_SHA256}  /tmp/fossflow.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/fossflow.tar.gz --strip-components=1; \
    for p in /patches/*.patch; do patch -p1 --forward < "$p"; done
RUN set -eux; \
    npm ci --no-audit --no-fund; \
    npm run build:lib; \
    npm run build:app
# The production dependencies of the backend alone, at the versions of the lockfile (the upstream image resolves
# them again at build time, without the lockfile).
RUN set -eux; \
    mkdir -p /backend/packages; \
    cp package.json package-lock.json /backend/; \
    for p in packages/*; do mkdir "/backend/$p"; cp "$p/package.json" "/backend/$p/"; done; \
    cp packages/fossflow-backend/server.js /backend/packages/fossflow-backend/; \
    cd /backend; \
    npm ci --omit=dev --workspace=fossflow-backend --ignore-scripts --no-audit --no-fund

FROM docker.io/library/node:24-alpine3.24

ARG VERSION
LABEL org.opencontainers.image.title="fossflow" \
      org.opencontainers.image.description="FossFLOW on Alpine, non-root, read-only root filesystem, rebuilt weekly by UnxWares" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="UnxWares" \
      org.opencontainers.image.source="https://github.com/UnxWares/helm"

# npm, npx, corepack and Yarn are not needed at runtime. tini forwards SIGTERM to the entrypoint, which stops nginx
# and the backend gracefully.
RUN set -eux; \
    apk upgrade --no-cache; \
    apk add --no-cache nginx tini; \
    rm -rf /usr/local/lib/node_modules /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
           /usr/local/bin/yarn /usr/local/bin/yarnpkg /opt/yarn-*; \
    mkdir -p /data/diagrams; \
    chown node:node /data/diagrams

COPY --from=build /src/packages/fossflow-app/build /usr/share/nginx/html
COPY --from=build /backend/node_modules /app/node_modules
COPY --from=build /backend/packages/fossflow-backend /app/packages/fossflow-backend
COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /usr/local/bin/fossflow-entrypoint

ENV NODE_ENV=production \
    DOTENV_CONFIG_QUIET=true \
    ENABLE_SERVER_STORAGE=true \
    STORAGE_PATH=/data/diagrams \
    BACKEND_HOST=127.0.0.1 \
    BACKEND_PORT=3001

USER 1000:1000
EXPOSE 8080
ENTRYPOINT ["/sbin/tini", "--", "fossflow-entrypoint"]
