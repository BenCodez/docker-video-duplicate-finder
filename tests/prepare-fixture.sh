#!/bin/sh
set -eux

FIXTURE_DIR="${1:-/storage}"

# Print loader inputs before executing FFmpeg, so startup failures in either
# architecture identify the selected binaries, shared libraries and preload.
uname -m
if [ -f /etc/alpine-release ]; then cat /etc/alpine-release; fi
printf 'PATH=%s\nLD_LIBRARY_PATH=%s\nLD_PRELOAD=%s\n' \
    "$PATH" "${LD_LIBRARY_PATH:-}" "${LD_PRELOAD:-}"
for TOOL in ffmpeg ffprobe ffplay; do
    TOOL_PATH="$(command -v "$TOOL")"
    ls -l "$TOOL_PATH"
    ldd "$TOOL_PATH" || true
done
ffmpeg -hide_banner -version
ffprobe -hide_banner -version

# Keep the original native encode as a required gate; a failed encode must not
# be replaced with a different codec, source or CPU-dispatch mode.
if ffmpeg -nostdin -v error -f lavfi -i testsrc=size=160x90:rate=5 -t 2 -c:v ffv1 "$FIXTURE_DIR/example-a.mkv"; then
    :
else
    FAILURE_STATUS=$?
    printf 'Native fixture failed with status %s; collecting debug output.\n' "$FAILURE_STATUS" >&2
    ffmpeg -nostdin -v debug -f lavfi -i testsrc=size=160x90:rate=5 -t 2 -c:v ffv1 \
        "$FIXTURE_DIR/diagnostic-encode.mkv" || true
    if command -v gdb >/dev/null 2>&1; then
        gdb --batch -ex 'set pagination off' -ex run -ex 'thread apply all bt' \
            --args ffmpeg -nostdin -v debug -f lavfi -i testsrc=size=160x90:rate=5 \
            -t 2 -c:v ffv1 "$FIXTURE_DIR/diagnostic-backtrace.mkv" || true
    fi
    exit "$FAILURE_STATUS"
fi
cp "$FIXTURE_DIR/example-a.mkv" "$FIXTURE_DIR/example-b.mkv"
printf '%s\n' '<movie><tag>Favorite</tag></movie>' > "$FIXTURE_DIR/example-a.nfo"
