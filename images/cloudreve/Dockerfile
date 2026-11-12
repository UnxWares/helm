# Cloudreve built from the release sources, with the Go module updates of patches/ (reported upstream in
# cloudreve/cloudreve#3618; 0002 adds golang.org/x/crypto v0.59.0, rardecode v2.2.0 with mholt/archives v0.1.5,
# klauspost/compress v1.20.2 and brotli v1.2.7; base64Captcha keeps its 2019 version, see .trivyignore), on a
# current Alpine. The runtime keeps the thumbnail and media tools of the upstream image (libvips, FFmpeg,
# LibreOffice, libheif, libraw); aria2 and supervisord are left out (the chart starts the binary directly), and so is
# the Asia/Shanghai default time zone (the chart sets TZ).
ARG VERSION=4.19.1

# Web UI: the cloudreve/frontend commit the 4.19.1 tag points to (its "assets" submodule), built as
# .build/build-assets.sh does, then embedded into the binary as application/statics/assets.zip.
FROM docker.io/library/node:24-alpine3.24 AS frontend
ARG VERSION
ARG FRONTEND_COMMIT=19da0fe1ecd40971fafa813983d769fdce41573c
ARG FRONTEND_SHA256=38c14a3d386f41eaf583119bc75f4239cc21ddfc801ed2d8c7a87fb448726ef8
WORKDIR /src
RUN set -eux; \
    apk add --no-cache zip; \
    wget -q -O /tmp/frontend.tar.gz "https://github.com/cloudreve/frontend/archive/${FRONTEND_COMMIT}.tar.gz"; \
    echo "${FRONTEND_SHA256}  /tmp/frontend.tar.gz" | sha256sum -c -; \
    mkdir assets; \
    tar -xzf /tmp/frontend.tar.gz -C assets --strip-components=1; \
    cd assets; \
    yarn install --frozen-lockfile --network-timeout 1000000; \
    yarn version --new-version "$VERSION" --no-git-tag-version; \
    NODE_OPTIONS=--max-old-space-size=4096 yarn run build; \
    cd ..; \
    zip -q -r /assets.zip assets/build

FROM docker.io/library/golang:1.26-alpine3.24 AS backend
ARG VERSION
ARG CLOUDREVE_COMMIT=a8becb9
ARG CLOUDREVE_SHA256=9dcc03653be86c412770a1f747d6c2dae3a677a17c623f40f0cb6f8b30a5803f
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
WORKDIR /src
COPY patches/ /patches/
RUN set -eux; \
    apk add --no-cache patch; \
    wget -q -O /tmp/cloudreve.tar.gz "https://github.com/cloudreve/cloudreve/archive/refs/tags/${VERSION}.tar.gz"; \
    echo "${CLOUDREVE_SHA256}  /tmp/cloudreve.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/cloudreve.tar.gz --strip-components=1; \
    for p in /patches/*.patch; do patch -p1 --forward < "$p"; done
COPY --from=frontend /assets.zip application/statics/assets.zip
RUN set -eux; \
    go build -trimpath -o /cloudreve -ldflags "-s -w \
        -X 'github.com/cloudreve/Cloudreve/v4/application/constants.BackendVersion=${VERSION}' \
        -X 'github.com/cloudreve/Cloudreve/v4/application/constants.LastCommit=${CLOUDREVE_COMMIT}'" .; \
    go version -m /cloudreve | head -1

FROM docker.io/library/alpine:3.24
RUN set -eux; \
    apk upgrade --no-cache; \
    apk add --no-cache tzdata vips-tools ffmpeg libreoffice font-noto font-noto-cjk libheif libraw-tools; \
    mkdir -p /cloudreve/data; \
    chown 1000:1000 /cloudreve/data
COPY --from=backend /cloudreve /cloudreve/cloudreve

# Thumbnail and media settings of the upstream image.
ENV CR_SETTING_DEFAULT_thumb_ffmpeg_enabled=1 \
    CR_SETTING_DEFAULT_thumb_vips_enabled=1 \
    CR_SETTING_DEFAULT_thumb_libreoffice_enabled=1 \
    CR_SETTING_DEFAULT_media_meta_ffprobe=1 \
    CR_SETTING_DEFAULT_thumb_libraw_enabled=1

WORKDIR /cloudreve
USER 1000:1000
EXPOSE 5212
VOLUME ["/cloudreve/data"]
ENTRYPOINT ["/cloudreve/cloudreve"]
