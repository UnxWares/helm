# Taiga front on nginx-unprivileged (Alpine, slim variant): non-root, port 8080, read-only root
# filesystem friendly. Bundles the Slack, GitHub, GitLab and UnxWares OIDC plugins, enabled with the same
# environment variables as taigaio/taiga-front (plus ENABLE_OIDC_AUTH, OIDC_BUTTON_TEXT, OIDC_BUTTON_LOGO and
# DEFAULT_LOGIN_ENABLED).
FROM docker.io/library/node:22-alpine3.24 AS oidc

ARG OIDC_COMMIT=c3e346d54d4ff08057373bf4fb8f23c426a7eed9
ARG OIDC_SHA256=a645d4531419f30b3d247d677da8e11ad6d3627fd3b2fa704efe603ef50c42b3

WORKDIR /build
RUN set -eux; \
    wget -q -O oidc.tar.gz "https://github.com/UnxWares/taiga-contrib-oidc-auth/archive/${OIDC_COMMIT}.tar.gz"; \
    echo "${OIDC_SHA256}  oidc.tar.gz" | sha256sum -c -; \
    tar -xzf oidc.tar.gz --strip-components=1; \
    cd front; \
    npm install --no-audit --no-fund; \
    npx gulp build; \
    cp oidc-auth.json dist/

FROM docker.io/library/alpine:3.24 AS dist

ARG VERSION=6.10.3
ARG DIST_SHA256=343eed6c5bcddb1a2a19ca54b121a21e49ef2f580c54e7e0089549315e2c3978
ARG TEMPLATE_SHA256=82937d59c7ce298637caa6a27548ac061b0c5882221e57defe0ccb72e1dcc0b1
ARG CONTRIBS_VERSION=6.10.0
ARG SLACK_SHA256=ae66a0653c415fddb7d002d832cdd33659e017f1a25200c511c6153fb432d097
ARG GITHUB_AUTH_SHA256=b2a804ffe8e70b1777841c888814800253168795fb0a3836953c93856970667b
ARG GITLAB_AUTH_SHA256=ab11abdd2107bb1370c8131d805b4b2fb5c55c3ef26fcf9e8bf7118cad7f5585

WORKDIR /build
RUN set -eux; \
    fetch() { wget -q -O "$1.tar.gz" "$2"; echo "$3  $1.tar.gz" | sha256sum -c -; mkdir "$1"; tar -xzf "$1.tar.gz" --strip-components=1 -C "$1"; }; \
    fetch dist "https://github.com/taigaio/taiga-front-dist/archive/refs/tags/${VERSION}.tar.gz" "${DIST_SHA256}"; \
    fetch slack "https://github.com/taigaio/taiga-contrib-slack/archive/refs/tags/${CONTRIBS_VERSION}.tar.gz" "${SLACK_SHA256}"; \
    fetch github-auth "https://github.com/taigaio/taiga-contrib-github-auth/archive/refs/tags/${CONTRIBS_VERSION}.tar.gz" "${GITHUB_AUTH_SHA256}"; \
    fetch gitlab-auth "https://github.com/taigaio/taiga-contrib-gitlab-auth/archive/refs/tags/${CONTRIBS_VERSION}.tar.gz" "${GITLAB_AUTH_SHA256}"; \
    wget -q -O dist/dist/conf.json.template "https://raw.githubusercontent.com/taigaio/taiga-front/${VERSION}/docker/conf.json.template"; \
    echo "${TEMPLATE_SHA256}  dist/dist/conf.json.template" | sha256sum -c -; \
    # OIDC settings, and the default login form as a setting (DEFAULT_LOGIN_ENABLED).
    sed -i \
        -e 's/"defaultLoginEnabled": true,/"defaultLoginEnabled": ${DEFAULT_LOGIN_ENABLED},/' \
        -e '/"gitLabUrl": "\${GITLAB_URL}",/a\    "oidcButtonText": "${OIDC_BUTTON_TEXT}",\n    "oidcButtonImage": "${OIDC_BUTTON_LOGO}",\n    "oidcMountPoint": "${TAIGA_SUBPATH}/api/oidc",' \
        dist/dist/conf.json.template; \
    mkdir -p dist/dist/plugins; \
    for p in slack github-auth gitlab-auth; do cp -r "$p/front/dist" "dist/dist/plugins/$p"; done

FROM docker.io/nginxinc/nginx-unprivileged:1.30.6-alpine3.24-slim

ARG VERSION=6.10.3
LABEL org.opencontainers.image.title="taiga-front" \
      org.opencontainers.image.description="Taiga front on nginx-unprivileged (Alpine slim), with the OIDC plugin, rebuilt weekly by UnxWares" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.vendor="UnxWares" \
      org.opencontainers.image.source="https://github.com/UnxWares/helm"

USER root
RUN apk upgrade --no-cache
USER 101

COPY --from=dist /build/dist/dist /usr/share/nginx/html
COPY --from=oidc /build/front/dist /usr/share/nginx/html/plugins/oidc-auth
COPY default.conf /etc/nginx/conf.d/default.conf
COPY 40-taiga-config.sh /docker-entrypoint.d/40-taiga-config.sh
