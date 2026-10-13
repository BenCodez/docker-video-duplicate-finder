#!/bin/sh

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error.

# Set same default compilation flags as abuild.
export CFLAGS="-fomit-frame-pointer"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="$CFLAGS"
export LDFLAGS="-fuse-ld=lld -Wl,--as-needed,-O1,--sort-common -Wl,--strip-all"

export CC=xx-clang
export CXX=xx-clang++

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() {
    echo ">>> $*"
}

FFMPEG_URL="${1:-}"
FFMPEG_SHA256="${2:-}"

if [ -z "$FFMPEG_URL" ]; then
    log "ERROR: FFmpeg URL missing."
    exit 1
fi
if [ "${#FFMPEG_SHA256}" -ne 64 ] || \
    ! printf '%s\n' "$FFMPEG_SHA256" | grep -Eq '^[0-9a-f]{64}$'; then
    log "ERROR: A pinned FFmpeg source SHA256 is required."
    exit 1
fi

#
# Install required packages.
#
HOST_PKGS=" \
    curl \
    build-base \
    clang \
    lld \
    llvm \
    nasm \
    pkgconfig \
"

TARGET_PKGS="\
    g++ \
    sdl2-dev \
    dav1d-dev \
    libva-dev \
    libvdpau-dev \
    vulkan-loader-dev \
"

_asm=
_onevpl=
case "$(xx-info arch)" in
    amd64)
        _onevpl="--enable-libvpl"
        TARGET_PKGS="$TARGET_PKGS libvpl-dev"
        ;;
    386)
        _asm="--disable-asm"
        ;;
    arm64)
        ;;
    arm)
        ;;
    *)
        echo "ERROR: Unsupported architecture: $(xx-info arch)"
        exit 1
        ;;
esac

log "Installing required Alpine packages..."
apk --no-cache add $HOST_PKGS
xx-apk --no-cache --no-scripts add $TARGET_PKGS
xx-clang --setup-target-triple

#
# Download sources.
#

log "Downloading FFmpeg package..."
mkdir /tmp/ffmpeg
curl --fail --show-error --location --retry 3 "$FFMPEG_URL" -o /tmp/ffmpeg-source.tar.xz
printf '%s  %s\n' "$FFMPEG_SHA256" /tmp/ffmpeg-source.tar.xz | sha256sum -c -
tar xJf /tmp/ffmpeg-source.tar.xz --strip 1 -C /tmp/ffmpeg

#
# Compile FFmpeg.
#

log "Configuring FFmpeg..."
(
    CROSS_FLAGS=
    if xx-info is-cross; then
        CROSS_FLAGS="\
            --enable-cross-compile \
            --arch=$(xx-info pkg-arch) \
            --target-os=linux \
        "
    fi

    cd /tmp/ffmpeg && \
    ./configure \
        $CROSS_FLAGS \
        --cc=xx-clang \
        --cxx=xx-clang++ \
        --strip=$(xx-info)-strip \
        --pkg-config=$(xx-info)-pkg-config \
        --prefix=/usr \
        --optflags="-O3" \
        --disable-doc \
        --disable-network \
        --enable-shared \
        --disable-static \
        $_asm \
        --enable-gpl \
        --enable-version3 \
        --enable-pic \
        --enable-pthreads \
        --enable-libdav1d \
        --enable-vaapi \
        --enable-vdpau \
        --enable-vulkan \
        $_onevpl \
)

log "Compiling FFmpeg..."
make -C /tmp/ffmpeg -j$(nproc)

log "Installing FFmpeg..."
DESTDIR=/tmp/ffmpeg-install make -C /tmp/ffmpeg install
rm -r /tmp/ffmpeg-install/usr/lib/pkgconfig
mkdir -p /tmp/ffmpeg-install/usr/share/licenses/ffmpeg
cp /tmp/ffmpeg/COPYING.GPLv3 /tmp/ffmpeg-install/usr/share/licenses/ffmpeg/LICENSE
cp /tmp/ffmpeg-source.tar.xz /tmp/ffmpeg-install/usr/share/licenses/ffmpeg/CorrespondingSource.tar.xz
printf 'source=%s\nsha256=%s\n' "$FFMPEG_URL" "$FFMPEG_SHA256" > /tmp/ffmpeg-install/usr/share/licenses/ffmpeg/source-info.txt
