#
# video-duplicate-finder Dockerfile
#
# https://github.com/BenCodez/docker-video-duplicate-finder
# Based on https://github.com/jlesage/docker-video-duplicate-finder (MIT).
#

# Docker image version is provided via build arg.
ARG DOCKER_IMAGE_VERSION=
ARG DOCKER_IMAGE_REVISION=unknown

# Define software versions.
ARG VIDEO_DUPLICATE_FINDER_COMMIT_SHA=f1e5ff22f8da80cb70dd82fe0afac868590a094a
ARG VIDEO_DUPLICATE_FINDER_VERSION=4.1.1-fork
ARG DOTNET_SDK_VERSION=10.0.401
ARG FFMPEG_VERSION=8.1.3
ARG FFMPEG_SHA256=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3

# Define software download URLs.
ARG VIDEO_DUPLICATE_FINDER_URL=https://github.com/BenCodez/videoduplicatefinder/archive/${VIDEO_DUPLICATE_FINDER_COMMIT_SHA}.tar.gz
ARG FFMPEG_URL=https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz

# Get Dockerfile cross-compilation helpers.
FROM --platform=$BUILDPLATFORM tonistiigi/xx:1.9.0 AS xx

# Build Video Duplicate Finder.
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:${DOTNET_SDK_VERSION}-alpine3.24 AS vdf
ARG TARGETPLATFORM
ARG VIDEO_DUPLICATE_FINDER_URL
ARG VIDEO_DUPLICATE_FINDER_VERSION
ARG VIDEO_DUPLICATE_FINDER_COMMIT_SHA
ARG DOTNET_SDK_VERSION
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
COPY --from=xx / /
COPY src/vdf /build
RUN /build/build.sh "$VIDEO_DUPLICATE_FINDER_URL" "$VIDEO_DUPLICATE_FINDER_VERSION" "$VIDEO_DUPLICATE_FINDER_COMMIT_SHA" "$DOTNET_SDK_VERSION"
RUN xx-verify /tmp/vdf-install/VDF.GUI

# Build FFmpeg.
FROM --platform=$BUILDPLATFORM alpine:3.24 AS ffmpeg
ARG TARGETPLATFORM
ARG FFMPEG_URL
ARG FFMPEG_SHA256
COPY --from=xx / /
COPY src/ffmpeg /build
RUN /build/build.sh "$FFMPEG_URL" "$FFMPEG_SHA256"
RUN xx-verify \
    /tmp/ffmpeg-install/usr/bin/ffmpeg \
    /tmp/ffmpeg-install/usr/bin/ffplay \
    /tmp/ffmpeg-install/usr/bin/ffprobe \
    /tmp/ffmpeg-install/usr/lib/lib*.so.*

# Pull base image.
FROM jlesage/baseimage-gui:alpine-3.24-v4.14.0

ARG TARGETARCH
ARG VIDEO_DUPLICATE_FINDER_VERSION
ARG VIDEO_DUPLICATE_FINDER_COMMIT_SHA
ARG DOTNET_SDK_VERSION
ARG DOCKER_IMAGE_VERSION
ARG DOCKER_IMAGE_REVISION

# Define working directory.
WORKDIR /tmp

# Install dependencies.
RUN \
    [ "${TARGETARCH:-amd64}" = "amd64" ] && _onevpl=libvpl || _onevpl=; \
    add-pkg \
        gtk+3.0 \
        harfbuzz \
        icu-libs \
        libice \
        libsm \
        libunwind \
        sdl2 \
        libdrm \
        libpulse \
        libva \
        libvdpau \
        $_onevpl \
        adwaita-icon-theme \
        hicolor-icon-theme \
        font-dejavu \
        pcmanfm \
        jq \
        # ONNX Runtime for AI matching.
        onnxruntime \
        && \
    # Fix for pcmanfm using "tab-new" icon, missing in Adwaita and hicolor themes.
    add-pkg mate-icon-theme && \
    cp /usr/share/icons/mate/16x16/actions/tab-new.png /usr/share/icons/hicolor/16x16/actions/ && \
    cp /usr/share/icons/mate/22x22/actions/tab-new.png /usr/share/icons/hicolor/22x22/actions/ && \
    cp /usr/share/icons/mate/24x24/actions/tab-new.png /usr/share/icons/hicolor/24x24/actions/ && \
    del-pkg mate-icon-theme && \
    add-pkg gtk-update-icon-cache && \
    gtk-update-icon-cache /usr/share/icons/hicolor && \
    del-pkg gtk-update-icon-cache && \
    true

# Generate and install favicons.
RUN \
    APP_ICON_URL=https://raw.githubusercontent.com/jlesage/docker-templates/master/jlesage/images/video-duplicate-finder-icon.png && \
    install_app_icon.sh "$APP_ICON_URL"

# Add files.
COPY rootfs/ /
COPY --from=vdf /tmp/vdf-install /opt/vdf
COPY --from=ffmpeg /tmp/ffmpeg-install/usr/bin/ffmpeg /usr/bin/ffmpeg
COPY --from=ffmpeg /tmp/ffmpeg-install/usr/bin/ffplay /usr/bin/ffplay
COPY --from=ffmpeg /tmp/ffmpeg-install/usr/bin/ffprobe /usr/bin/ffprobe
COPY --from=ffmpeg /tmp/ffmpeg-install/usr/lib /usr/lib
COPY --from=ffmpeg /tmp/ffmpeg-install/usr/share/licenses /usr/share/licenses
COPY LICENSE /usr/share/licenses/container/LICENSE
COPY Dockerfile src/vdf/ /usr/share/vdf/container-build/
COPY src/ffmpeg/build.sh /usr/share/vdf/container-build/ffmpeg-build.sh
COPY src/ffmpeg/check-stack.sh /usr/share/vdf/container-build/check-stack.sh

# Avoid mixed private HarfBuzz object layouts through musl symbol interposition.
# Validate every C import of the pinned managed wrapper before selecting the
# same native library that GTK/Pango use. binutils is a build-time check only.
RUN add-pkg binutils && \
    sh /usr/share/vdf/container-build/use-system-harfbuzz.sh && \
    apk list --installed harfbuzz >> /opt/vdf/NativeFontRuntime.txt && \
    mkdir -p /usr/share/licenses/harfbuzz && \
    cp /usr/share/vdf/container-build/HARFBUZZ-COPYING /usr/share/licenses/harfbuzz/COPYING && \
    del-pkg binutils

# Set internal environment variables.
RUN \
    set-cont-env APP_NAME "Video Duplicate Finder" && \
    set-cont-env APP_VERSION "$VIDEO_DUPLICATE_FINDER_VERSION" && \
    set-cont-env DOCKER_IMAGE_VERSION "$DOCKER_IMAGE_VERSION" && \
    true

# Define mountable directories.
VOLUME ["/config", "/storage"]

# Metadata.
LABEL \
      org.label-schema.name="video-duplicate-finder" \
      org.label-schema.description="Docker container for Video Duplicate Finder" \
      org.label-schema.version="${DOCKER_IMAGE_VERSION:-unknown}" \
      org.label-schema.vcs-url="https://github.com/BenCodez/docker-video-duplicate-finder" \
      org.label-schema.schema-version="1.0" \
      org.opencontainers.image.source="https://github.com/BenCodez/docker-video-duplicate-finder" \
      org.opencontainers.image.revision="${DOCKER_IMAGE_REVISION}" \
      org.opencontainers.image.licenses="MIT AND AGPL-3.0-or-later AND GPL-3.0-or-later" \
      io.bencodez.vdf.source="https://github.com/BenCodez/videoduplicatefinder" \
      io.bencodez.vdf.revision="${VIDEO_DUPLICATE_FINDER_COMMIT_SHA}" \
      io.bencodez.vdf.sdk="${DOTNET_SDK_VERSION}"
