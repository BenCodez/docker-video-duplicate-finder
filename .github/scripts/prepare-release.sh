#!/bin/bash
set -euo pipefail

APP_COMMIT="${REQUESTED_COMMIT:-$(sed -n 's/^ARG VIDEO_DUPLICATE_FINDER_COMMIT_SHA=//p' Dockerfile)}"
[[ "$APP_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo '::error::Application source requires a full lowercase commit SHA'; exit 1; }
TAG="test-${GITHUB_SHA:0:12}"
PUBLISH=false
LATEST=false
if [[ "$GITHUB_EVENT_NAME" == push && "$GITHUB_REF" == refs/tags/* ]]; then
    TAG="${GITHUB_REF#refs/tags/}"
    [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$ ]] || { echo '::error::Use a vX.Y.Z version tag'; exit 1; }
    PUBLISH=true
elif [[ "$GITHUB_EVENT_NAME" == workflow_dispatch ]]; then
    TAG="${REQUESTED_TAG:-test}"
    PUBLISH="${REQUESTED_PUBLISH:-false}"
    LATEST="${REQUESTED_LATEST:-false}"
fi
[[ "$TAG" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ && "$TAG" != latest ]] || { echo '::error::Invalid or reserved image tag'; exit 1; }
if [[ "$LATEST" == true ]]; then
    [[ "$PUBLISH" == true && "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo '::error::latest requires an explicit published stable release'; exit 1; }
fi
[[ "$GITHUB_REPOSITORY" == BenCodez/docker-video-duplicate-finder ]] || PUBLISH=false
echo "application_commit=$APP_COMMIT" >> "$GITHUB_OUTPUT"
echo "image_tag=$TAG" >> "$GITHUB_OUTPUT"
echo "commit_tag=sha-${GITHUB_SHA:0:12}-${APP_COMMIT:0:12}" >> "$GITHUB_OUTPUT"
echo "publish=$PUBLISH" >> "$GITHUB_OUTPUT"
echo "promote_latest=$LATEST" >> "$GITHUB_OUTPUT"
