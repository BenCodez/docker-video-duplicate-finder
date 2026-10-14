#!/bin/sh
# Failure-only diagnostics for the generated CI configuration and media.
set -eu
IMAGE="${1:?image required}"
PLATFORM="${2:?platform required}"
WORK_DIR="${3:?fixture directory required}"
CONTAINER="${4:?container name required}-diagnostic"
SMOKE_UID="${5:?user ID required}"
SMOKE_GID="${6:?group ID required}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# The failed normal run has stopped. Preserve its files and inspect a copy.
cp -a "$WORK_DIR/config" "$WORK_DIR/diagnostic-config"
if [ -f "$WORK_DIR/config/log.txt" ]; then cat "$WORK_DIR/config/log.txt"; fi
docker run -d --platform "$PLATFORM" --name "$CONTAINER" \
    --entrypoint /bin/sh \
    --cap-add=SYS_PTRACE \
    -e TZ=Etc/UTC -e USER_ID="$SMOKE_UID" -e GROUP_ID="$SMOKE_GID" -e DARK_MODE=1 \
    -e DOTNET_DbgEnableMiniDump=1 -e DOTNET_EnableCrashReportOnly=1 \
    -e DOTNET_DbgMiniDumpName=/config/gui-startup.%p -e DOTNET_CreateDumpDiagnostics=1 \
    -v "$WORK_DIR/diagnostic-config:/config:rw" -v "$WORK_DIR/media:/storage:ro" \
    "$IMAGE" -c 'chmod a+x /opt/vdf/createdump && exec /init' >/dev/null
DEADLINE=$(( $(date +%s) + 90 ))
while [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" = true ]; do
    [ "$(date +%s)" -lt "$DEADLINE" ] || break
    sleep 2
done
docker logs "$CONTAINER" 2>/dev/null || true
python3 "$SCRIPT_DIR/print-crash-report.py" "$WORK_DIR/diagnostic-config"
