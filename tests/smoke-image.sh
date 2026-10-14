#!/bin/sh
set -eu

IMAGE="${1:?usage: smoke-image.sh IMAGE}"
PLATFORM="${PLATFORM:-linux/amd64}"
WORK_DIR="$(mktemp -d)"
CONTAINER="vdf-smoke-$(basename "$WORK_DIR" | tr '[:upper:]' '[:lower:]')"
SMOKE_UID="$(id -u)"
SMOKE_GID="$(id -g)"
[ "$SMOKE_UID" -ne 0 ] || SMOKE_UID=1000
[ "$SMOKE_GID" -ne 0 ] || SMOKE_GID=1000
cleanup() {
    result=$?
    if [ "$result" -ne 0 ]; then
        docker logs "$CONTAINER" 2>/dev/null || true
        if docker inspect "$CONTAINER" >/dev/null 2>&1; then
            # Only this failure-only replay grants ptrace. It cannot pass a gate.
            if docker stop "$CONTAINER" >/dev/null 2>&1; then
                timeout 300 sh "$(dirname "$0")/diagnose-gui.sh" \
                    "$IMAGE" "$PLATFORM" "$WORK_DIR" "$CONTAINER" "$SMOKE_UID" "$SMOKE_GID" || true
            fi
        fi
    fi
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "$WORK_DIR/config" "$WORK_DIR/media"

# The only media and configuration used here are generated fixtures.
docker run --interactive --rm --platform "$PLATFORM" --entrypoint /bin/sh \
    -v "$WORK_DIR/media:/storage" "$IMAGE" -s \
    < "$(dirname "$0")/prepare-fixture.sh"
python3 - "$WORK_DIR/config/Settings.json" "$WORK_DIR/config/ScannedFiles.db" <<'PY'
from datetime import datetime, timedelta, timezone
import json, struct, sys
settings = {
    "Includes": ["/storage"], "UseNativeFfmpegBinding": True,
    "HardwareAccelerationMode": 0, "Percent": 94.0,
    "EnableScheduledScan": True,
    "ScheduledScanTime": (datetime.now(timezone.utc) + timedelta(minutes=2)).strftime("%H:%M"),
    "NotifyOnScheduledScanComplete": False, "NotifyOnScanComplete": False,
    "GeneratePreviewThumbnails": True, "BackupAfterListChanged": True,
    "AskToSaveResultsOnExit": False,
    "MaxDegreeOfParallelism": 1, "MatchingMaxDegreeOfParallelism": 1,
    "LanguageCode": "en",
    "NfoFavourites": {"Enabled": True},
    "AutomationSelection": {
        "AutoAfterScan": True,
        "FolderRules": [{"Directory": "/storage", "Priority": 10, "Enabled": True, "Recursive": True}]
    }
}
with open(sys.argv[1], "w") as file: json.dump(settings, file)
# A configured desktop install has already chosen its database algorithm. This
# is a valid empty VDFDB002 (version 3, current image pipeline, end marker), so
# first-run algorithm setup does not require an interactive browser connection.
with open(sys.argv[2], "wb") as file: file.write(b"VDFDB002" + struct.pack("<iii", 3, 1, -1))
PY
cp -a "$WORK_DIR/config" "$WORK_DIR/pristine-config"

start_container() {
    docker run -d --platform "$PLATFORM" --name "$CONTAINER" \
        -e TZ=Etc/UTC -e USER_ID="$SMOKE_UID" -e GROUP_ID="$SMOKE_GID" -e DARK_MODE="$1" \
        -p 127.0.0.1::5800 -p 127.0.0.1::5900 \
        -v "$WORK_DIR/config:/config:rw" -v "$WORK_DIR/media:/storage:ro" "$IMAGE" >/dev/null
}
start_container 1

# Do not open a browser, HTTP, or VNC connection until the scheduled scan finishes.
# This exercises the running desktop scheduler rather than a separate scan service.
DEADLINE=$(( $(date +%s) + 420 ))
until [ -s "$WORK_DIR/config/ScannedFiles.db" ] && \
    [ -f "$WORK_DIR/config/log.txt" ] && grep -q 'Scan done\.' "$WORK_DIR/config/log.txt" && \
    [ -s "$WORK_DIR/config/SelectionPlan.json" ] && [ -s "$WORK_DIR/config/ReviewedFiles.json" ] && \
    [ -s "$WORK_DIR/config/backup.scanresults" ] && \
    jq -e '.ScheduledLastStatus == "Completed"' "$WORK_DIR/config/Settings.json" >/dev/null 2>&1
do
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" = true ] || { echo 'Container exited before scheduled scan'; exit 1; }
    [ "$(date +%s)" -lt "$DEADLINE" ] || { echo 'Scheduled scan did not finish without a browser'; exit 1; }
    sleep 5
done
python3 - "$WORK_DIR/config/SelectionPlan.json" "$WORK_DIR/config/ReviewedFiles.json" "$WORK_DIR/config/backup.scanresults" <<'PY'
import json, sys, zipfile
with open(sys.argv[1]) as file: envelope = json.load(file)
assert envelope["version"] == 1
decisions = {decision["path"]: decision for decision in envelope["plan"]["decisions"]}
assert len(decisions) == 2, "The scheduled scan did not produce the expected duplicate group"
favourite = decisions["/storage/example-a.mkv"]
assert favourite["isProtected"] and not favourite["removeCandidate"], "NFO favourite lost protection"
candidate = decisions["/storage/example-b.mkv"]
assert candidate["removeCandidate"] and not candidate["isProtected"]
assert candidate["folderPriority"] == 10
with open(sys.argv[2]) as file: reviews = json.load(file)
assert len(reviews["records"]) == 2, "Selection reviews were not persisted under /config"
with zipfile.ZipFile(sys.argv[3]) as backup:
    results = json.loads(backup.read("scan.json"))
assert results["version"] == 1
assert {item["ItemInfo"]["Path"] for item in results["items"]} == set(decisions), "The backup did not preserve both GUI result rows"
PY
docker exec "$CONTAINER" pidof VDF.GUI >/dev/null
docker exec "$CONTAINER" sh -c 'test "$(readlink /opt/vdf/libHarfBuzzSharp.so)" = /usr/lib/libharfbuzz.so.0 && test -s /opt/vdf/NativeFontRuntime.txt' >/dev/null
test "$(wc -c < "$WORK_DIR/config/ScannedFiles.db")" -gt 20
docker exec "$CONTAINER" /opt/vdf/VDF.GUI --help | grep -q -- '--settings'
docker exec "$CONTAINER" sh -c 'command -v pcmanfm && command -v ffmpeg && command -v ffprobe && command -v ffplay && test -f /usr/lib/libonnxruntime.so.1' >/dev/null
WEB_PORT="$(docker port "$CONTAINER" 5800/tcp)"
VNC_PORT="$(docker port "$CONTAINER" 5900/tcp)"
curl --fail --show-error --silent "http://127.0.0.1:${WEB_PORT##*:}/" -o "$WORK_DIR/browser.html"
grep -qi '<html' "$WORK_DIR/browser.html"
python3 - "${VNC_PORT##*:}" <<'PY'
import socket, sys
with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=15) as connection:
    banner = b""
    while len(banner) < 12:
        chunk = connection.recv(12 - len(banner))
        assert chunk, "Port 5900 closed before the VNC handshake"
        banner += chunk
    assert banner.startswith(b"RFB "), "Port 5900 did not provide VNC"
PY
python3 - "$WORK_DIR/config/Settings.json" <<'PY'
import json, sys
with open(sys.argv[1]) as file: settings = json.load(file)
assert settings["ThemeMode"] == 2
assert settings["Includes"] == ["/storage"]
assert settings["Percent"] == 94.0
assert settings["NfoFavourites"]["Enabled"]
assert settings["AutomationSelection"]["AutoAfterScan"]
PY
docker stop -t 30 "$CONTAINER" >/dev/null
docker rm "$CONTAINER" >/dev/null

# Stop first, then disable the schedule on disk so graceful shutdown cannot restore it.
python3 - "$WORK_DIR/config/Settings.json" <<'PY'
import json, sys
with open(sys.argv[1]) as file: settings = json.load(file)
settings["EnableScheduledScan"] = False
with open(sys.argv[1], "w") as file: json.dump(settings, file)
PY
DATABASE_HASH="$(sha256sum "$WORK_DIR/config/ScannedFiles.db" | cut -d' ' -f1)"
PLAN_HASH="$(sha256sum "$WORK_DIR/config/SelectionPlan.json" | cut -d' ' -f1)"
review_snapshot() {
    python3 - "$WORK_DIR/config/ReviewedFiles.json" "$WORK_DIR/config/Settings.json" <<'PY'
import json, sys
with open(sys.argv[1]) as file: reviews = json.load(file)
with open(sys.argv[2]) as file: settings = json.load(file)
records = []
for record in reviews["records"]:
    records.append({field: record[field] for field in
        ("identity", "choice", "manuallyProtected", "automaticallySelected", "isKeeper", "profile")})
assert settings["ScheduledLastClaimedSlotUtc"], "The completed schedule slot was not persisted"
print(json.dumps({"records": records, "claimedSlot": settings["ScheduledLastClaimedSlotUtc"]}, sort_keys=True))
PY
}
review_snapshot > "$WORK_DIR/reviews-before.json"
cp "$WORK_DIR/config/ReviewedFiles.json" "$WORK_DIR/reviews-before-full.json"
reviews_refreshed() {
    python3 - "$WORK_DIR/reviews-before-full.json" "$WORK_DIR/config/ReviewedFiles.json" <<'PY'
from datetime import datetime
import json, sys
def timestamps(path):
    with open(path) as file: records = json.load(file)["records"]
    return {record["identity"]["path"]: datetime.fromisoformat(record["updatedUtc"].replace("Z", "+00:00")) for record in records}
before, after = (timestamps(path) for path in sys.argv[1:])
assert set(before) == set(after) and len(after) == 2
assert all(after[path] > before[path] for path in before), "Restart did not restore and process both reviewed GUI rows"
PY
}
touch "$WORK_DIR/restart-marker"
start_container 0
DEADLINE=$(( $(date +%s) + 120 ))
until docker exec "$CONTAINER" pidof VDF.GUI >/dev/null 2>&1 && \
    [ -f "$WORK_DIR/config/log.txt" ] && grep -q 'Previously scanned files imported\.' "$WORK_DIR/config/log.txt" && \
    [ "$WORK_DIR/config/ReviewedFiles.json" -nt "$WORK_DIR/restart-marker" ] && \
    reviews_refreshed >/dev/null 2>&1
do
    [ "$(date +%s)" -lt "$DEADLINE" ] || { echo 'GUI did not resume with the copied config'; exit 1; }
    sleep 3
done
python3 - "$WORK_DIR/config/Settings.json" <<'PY'
import json, sys
with open(sys.argv[1]) as file: settings = json.load(file)
assert settings["ThemeMode"] == 1
assert settings["Includes"] == ["/storage"]
assert settings["Percent"] == 94.0
assert not settings["EnableScheduledScan"]
assert settings["NfoFavourites"]["Enabled"]
assert settings["AutomationSelection"]["AutoAfterScan"]
PY
test "$DATABASE_HASH" = "$(sha256sum "$WORK_DIR/config/ScannedFiles.db" | cut -d' ' -f1)"
review_snapshot > "$WORK_DIR/reviews-after.json"
cmp "$WORK_DIR/reviews-before.json" "$WORK_DIR/reviews-after.json"
reviews_refreshed
test "$PLAN_HASH" = "$(sha256sum "$WORK_DIR/config/SelectionPlan.json" | cut -d' ' -f1)"
test -f "$WORK_DIR/media/example-a.mkv"
test -f "$WORK_DIR/media/example-b.mkv"
test -f "$WORK_DIR/media/example-a.nfo"
echo "PASS: $PLATFORM GUI, no-browser scheduled scan, NFO-protected selection, HTTP/VNC and persistent restart."
