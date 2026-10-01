# syntax=docker/dockerfile:1.7
#
# Two targets share one cached ZCode download:
#   web  (default) - Selkies/pixelflux: ZCode streamed to your browser over WebSockets
#   x11            - plain Ubuntu, window forwarded to XQuartz on the Mac
#
#   docker build --target web -t zcode:web .
#   docker build --target x11 -t zcode:x11 .

ARG ZCODE_VERSION=3.14.4
ARG ZCODE_CDN=https://cdn-zcode.z.ai/zcode/electron/releases
ARG NODE_VERSION=24

# Official Node build (current LTS), copied in so both targets get the same version.
FROM node:${NODE_VERSION}-slim AS node

# --- ZCode .deb, picked by target arch (only the matching stage is built) ---
FROM scratch AS deb-arm64
ARG ZCODE_VERSION ZCODE_CDN
ADD --link ${ZCODE_CDN}/${ZCODE_VERSION}/linux-arm64/ZCode-${ZCODE_VERSION}-linux-arm64.deb /zcode.deb

FROM scratch AS deb-amd64
ARG ZCODE_VERSION ZCODE_CDN
ADD --link ${ZCODE_CDN}/${ZCODE_VERSION}/linux-x64/ZCode-${ZCODE_VERSION}-linux-x64.deb /zcode.deb

FROM deb-${TARGETARCH} AS deb

# --- x11: minimal Ubuntu for XQuartz forwarding ---
FROM ubuntu:24.04 AS x11
ENV DEBIAN_FRONTEND=noninteractive
# apt resolves the .deb's own dependency list, so no hand-maintained lib list.
RUN --mount=type=bind,from=deb,source=/zcode.deb,target=/tmp/zcode.deb \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        /tmp/zcode.deb dbus procps socat ca-certificates fonts-noto-core fonts-noto-color-emoji
# Node + npm + corepack (pnpm/yarn on demand), version from NODE_VERSION.
COPY --link --from=node /usr/local/bin/node /usr/local/bin/node
COPY --link --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && ln -s ../lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack \
    && corepack enable
COPY --link --chmod=755 rootfs/usr/local/bin/ /usr/local/bin/
COPY --link rootfs/etc/ /etc/
# zcode-cli: the bundled CLI looks for its provider config next to itself; the .deb ships it one level up.
RUN link-catcher --install \
    && ln -s ../config/provider /opt/ZCode/resources/glm/provider
# User-editable tools from packages/ - last, so editing them only rebuilds this layer.
RUN --mount=type=bind,source=packages,target=/tmp/packages \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=cache,target=/root/.npm \
    install-packages /tmp/packages
ENV HOME=/config
ENTRYPOINT ["dbus-run-session", "--"]
CMD ["zcode"]

# --- web: Selkies streaming desktop (labwc + pixelflux), open in any browser ---
FROM ghcr.io/linuxserver/baseimage-selkies:ubunturesolute AS web
ENV DEBIAN_FRONTEND=noninteractive
RUN --mount=type=bind,from=deb,source=/zcode.deb,target=/tmp/zcode.deb \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/zcode.deb procps socat
# Node + npm + corepack (pnpm/yarn on demand), version from NODE_VERSION.
COPY --link --from=node /usr/local/bin/node /usr/local/bin/node
COPY --link --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && ln -s ../lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack \
    && corepack enable
COPY --link --chmod=755 rootfs/usr/local/bin/ /usr/local/bin/
COPY --link --chmod=755 rootfs/defaults/ /defaults/
COPY --link --chmod=755 rootfs/custom-cont-init.d/ /custom-cont-init.d/
COPY --link rootfs/etc/ /etc/
# zcode-cli: the bundled CLI looks for its provider config next to itself; the .deb ships it one level up.
# zcode-api: route /api/v1/ to it ahead of Selkies' catch-all /api, in both server blocks
# (init-nginx regenerates the live config from this template on every boot).
RUN link-catcher --install \
    && ln -s ../config/provider /opt/ZCode/resources/glm/provider \
    && sed -i 's|^\(\s*\)location SUBFOLDERapi {|\1include /etc/nginx/zcode-api.conf;\n&|' /defaults/default.conf \
    && [ "$(grep -c zcode-api.conf /defaults/default.conf)" = 2 ]
# User-editable tools from packages/ - last, so editing them only rebuilds this layer.
RUN --mount=type=bind,source=packages,target=/tmp/packages \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=cache,target=/root/.npm \
    install-packages /tmp/packages
ENV TITLE=ZCode \
    PIXELFLUX_WAYLAND=true \
    NO_DECOR=true \
    RESTART_APP=true
