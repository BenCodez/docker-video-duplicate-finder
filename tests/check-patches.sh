#!/bin/sh
set -eu

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APPLICATION_SOURCE="${1:?usage: check-patches.sh APPLICATION_SOURCE_DIR}"
APPLICATION_COMMIT="${2:-$(sed -n 's/^ARG VIDEO_DUPLICATE_FINDER_COMMIT_SHA=//p' "$REPO_DIR/Dockerfile")}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

# Audit a copy; never change the application checkout or any user configuration.
mkdir "$WORK_DIR/source"
tar -C "$APPLICATION_SOURCE" --exclude=.git --exclude='*/bin' --exclude='*/obj' -cf "$WORK_DIR/source.tar" .
tar -xf "$WORK_DIR/source.tar" -C "$WORK_DIR/source"
"$REPO_DIR/src/vdf/apply-patches.sh" "$WORK_DIR/source"

dotnet run --project "$REPO_DIR/tests/persistence-probe/PersistenceProbe.csproj" \
    --property:ApplicationSource="$WORK_DIR/source" \
    --property:VdfSourceCommit="$APPLICATION_COMMIT" \
    --property:BaseIntermediateOutputPath="$WORK_DIR/obj/" \
    --property:OutputPath="$WORK_DIR/bin/"
