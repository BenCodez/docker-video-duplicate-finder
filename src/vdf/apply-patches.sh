#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="${1:?usage: apply-patches.sh APPLICATION_SOURCE_DIR}"

for PATCH in \
    disable-appearance-settings.patch \
    disable-latest-release.patch \
    disable-drag-and-drop-hint.patch \
    fix-about-window-owner.patch \
    set-current-folder.patch \
    file-picker-suggested-start-location.patch \
    disable-ffmpeg-download.patch \
    use-system-onnxruntime.patch \
    build-provenance.patch
do
    echo "Applying $PATCH..."
    # Never hide stale contexts with fuzzy matches or accept reversed patches.
    patch --batch --forward --fuzz=0 -p1 -d "$SOURCE_DIR" < "$SCRIPT_DIR/$PATCH"
done
