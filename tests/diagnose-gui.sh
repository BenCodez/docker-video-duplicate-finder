#!/bin/sh
# Failure-only diagnostics for the generated CI configuration and media.
set -eu
IMAGE="${1:?image required}"
PLATFORM="${2:?platform required}"
WORK_DIR="${3:?fixture directory required}"
BASE_CONTAINER="${4:?container name required}-diagnostic"
SMOKE_UID="${5:?user ID required}"
SMOKE_GID="${6:?group ID required}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTAINER=
cleanup() { [ -z "$CONTAINER" ] || docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Kernel fault messages can identify a native module without changing the image.
if command -v sudo >/dev/null 2>&1; then
    sudo -n dmesg --ctime > "$WORK_DIR/kernel.log" 2>&1 || true
else
    dmesg --ctime > "$WORK_DIR/kernel.log" 2>&1 || true
fi
grep -Ei 'VDF\.GUI|segfault|general protection|Skia|HarfBuzz|permission denied|not permitted' "$WORK_DIR/kernel.log" | tail -80 || true
if [ -f "$WORK_DIR/config/log.txt" ]; then cat "$WORK_DIR/config/log.txt"; fi
echo 'Original post-crash configuration state:'
python3 "$SCRIPT_DIR/print-crash-report.py" "$WORK_DIR/config"
echo 'Pristine prelaunch configuration state:'
python3 "$SCRIPT_DIR/print-crash-report.py" "$WORK_DIR/pristine-config"
for SCENARIO in post-crash pristine pristine-report; do
    echo "GUI diagnostic replay: $SCENARIO"
    CONFIG_DIR="$WORK_DIR/diagnostic-config-$SCENARIO"
    case "$SCENARIO" in
        post-crash) SOURCE_DIR="$WORK_DIR/config" ;;
        *) SOURCE_DIR="$WORK_DIR/pristine-config" ;;
    esac
    cp -a "$SOURCE_DIR" "$CONFIG_DIR"
    CONTAINER="$BASE_CONTAINER-$SCENARIO"
    set -- docker run -d --platform "$PLATFORM" --name "$CONTAINER" \
        -e TZ=Etc/UTC -e USER_ID="$SMOKE_UID" -e GROUP_ID="$SMOKE_GID" -e DARK_MODE=1
    if [ "$SCENARIO" = pristine-report ]; then
        set -- "$@" --entrypoint /bin/sh --cap-add=SYS_PTRACE \
            -e DOTNET_DbgEnableMiniDump=1 -e DOTNET_EnableCrashReportOnly=1 \
            -e DOTNET_DbgMiniDumpName=/config/gui-startup.%p -e DOTNET_CreateDumpDiagnostics=1 \
            -e DOTNET_CreateDumpLogToFile=/config/createdump.log
    fi
    set -- "$@" -v "$CONFIG_DIR:/config:rw" -v "$WORK_DIR/media:/storage:ro" "$IMAGE"
    if [ "$SCENARIO" = pristine-report ]; then
        set -- "$@" -c 'chmod a+x /opt/vdf/createdump && exec /init'
    fi
    "$@" >/dev/null
    DEADLINE=$(( $(date +%s) + 90 ))
    while [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" = true ]; do
        [ "$(date +%s)" -lt "$DEADLINE" ] || break
        sleep 2
    done
    docker inspect -f '{{json .State}}' "$CONTAINER" || true
    docker exec "$CONTAINER" /bin/sh -c '
        ps
        for NAME in VDF.GUI createdump; do
            for PID in $(pidof "$NAME" 2>/dev/null || true); do
                echo "Diagnostic process: $NAME PID $PID"
                cat "/proc/$PID/status" "/proc/$PID/wchan" 2>/dev/null || true
                tr "\000" "\n" < "/proc/$PID/environ" | grep -E "^DOTNET_(DbgEnableMiniDump|EnableCrashReportOnly|DbgMiniDumpName|CreateDumpDiagnostics|CreateDumpLogToFile)=" || true
                grep -E "lib(SkiaSharp|HarfBuzzSharp|coreclr)|/VDF.GUI" "/proc/$PID/maps" || true
            done
        done
    ' || true
    docker logs "$CONTAINER" 2>/dev/null || true
    if [ -f "$CONFIG_DIR/log.txt" ]; then cat "$CONFIG_DIR/log.txt"; fi
    if [ -f "$CONFIG_DIR/createdump.log" ]; then cat "$CONFIG_DIR/createdump.log"; fi
    python3 "$SCRIPT_DIR/print-crash-report.py" "$CONFIG_DIR"
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    CONTAINER=
done
