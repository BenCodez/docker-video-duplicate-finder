#!/bin/sh

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() {
    echo ">>> $*"
}

VIDEO_DUPLICATE_FINDER_URL="${1:-}"
VIDEO_DUPLICATE_FINDER_VERSION="${2:-}"
VIDEO_DUPLICATE_FINDER_COMMIT_SHA="${3:-}"
DOTNET_SDK_VERSION="${4:-}"

if [ -z "$VIDEO_DUPLICATE_FINDER_URL" ]; then
    log "ERROR: Video Duplicate Finder URL missing."
    exit 1
fi

if [ -z "$VIDEO_DUPLICATE_FINDER_VERSION" ]; then
    log "ERROR: Video Duplicate Finder version missing."
    exit 1
fi

if [ "${#VIDEO_DUPLICATE_FINDER_COMMIT_SHA}" -ne 40 ] || \
    ! printf '%s\n' "$VIDEO_DUPLICATE_FINDER_COMMIT_SHA" | grep -Eq '^[0-9a-f]{40}$'; then
    log "ERROR: A full, lowercase application commit SHA is required."
    exit 1
fi
if [ -z "$DOTNET_SDK_VERSION" ] || [ "$(dotnet --version)" != "$DOTNET_SDK_VERSION" ]; then
    log "ERROR: The SDK must exactly match the pinned DOTNET_SDK_VERSION."
    exit 1
fi

#
# Install required packages.
#
apk --no-cache add \
    curl \
    patch

#
# Download sources.
#

log "Downloading Video Duplicate Finder package..."
mkdir /tmp/vdf
curl --fail --show-error --location --retry 3 "$VIDEO_DUPLICATE_FINDER_URL" -o /tmp/vdf-source.tar.gz
tar xzf /tmp/vdf-source.tar.gz --strip 1 -C /tmp/vdf

#
# Compile Video Duplicate Finder.
#

log "Patching Video Duplicate Finder..."
"$SCRIPT_DIR/apply-patches.sh" /tmp/vdf

# Determine the dotnet arch.
case "$(xx-info arch)" in
    amd64) dotnet_arch=x64;;
    arm64) dotnet_arch=arm64;;
    *) echo "ERROR: Unsupported arch: $(xx-info arch)." && exit 1;;
esac

log "Building Video Duplicate Finder..."
(
    cd /tmp/vdf
    # No roll-forward to a different SDK if the application gains a global.json.
    printf '{"sdk":{"version":"%s","rollForward":"disable"}}\n' "$DOTNET_SDK_VERSION" > global.json
    dotnet publish VDF.GUI/VDF.GUI.csproj \
        -c Release \
        --self-contained \
        -r "linux-musl-$dotnet_arch" \
        -p:Version="$VIDEO_DUPLICATE_FINDER_VERSION" \
        -p:VdfSourceCommit="$VIDEO_DUPLICATE_FINDER_COMMIT_SHA" \
        -o /tmp/vdf-install
)

# Include the exact patched source and attribution with the distributed binary.
mkdir -p /tmp/vdf-install/licenses/VDF
cp /tmp/vdf/LICENSE /tmp/vdf-install/licenses/VDF/LICENSE
tar -C /tmp/vdf --exclude='*/bin' --exclude='*/obj' -czf /tmp/vdf-install/CorrespondingSource.tar.gz .
printf 'repository=https://github.com/BenCodez/videoduplicatefinder\ncommit=%s\nsdk=%s\n' \
    "$VIDEO_DUPLICATE_FINDER_COMMIT_SHA" "$DOTNET_SDK_VERSION" > /tmp/vdf-install/source-info.txt
