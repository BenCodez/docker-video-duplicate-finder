"""Print bounded native/managed frames from .NET's synthetic CI crash report."""
import json
from pathlib import Path
import sys

directory = Path(sys.argv[1])
print("Generated configuration files:", sorted(str(file.relative_to(directory)) for file in directory.rglob("*") if file.is_file())[:100])
settings_file = directory / "Settings.json"
if settings_file.is_file():
    with settings_file.open() as stream:
        settings = json.load(stream)
    print("Replay settings/status:", json.dumps({field: settings.get(field) for field in
          ("ThemeMode", "EnableScheduledScan", "ScheduledScanTime", "ScheduledLastStatus",
           "ScheduledLastClaimedSlotUtc", "UseNativeFfmpegBinding", "HardwareAccelerationMode")}, sort_keys=True))
reports = sorted(directory.glob("gui-startup.*.crashreport.json"))
if not reports:
    print("No .NET crash report was produced; see container diagnostic logs.")
for file in reports[:4]:
    with file.open() as stream:
        report = json.load(stream)
    payload = report["payload"]
    print("GUI crash report:", file.name, payload.get("process_name"),
          report.get("parameters", {}))
    threads = sorted(payload["threads"], key=lambda thread: not thread.get("crashed", False))
    for thread in threads[:32]:
        print("Thread:", thread.get("native_thread_id"), "crashed:", thread.get("crashed"),
              "managed:", thread.get("is_managed"), "context:", thread.get("ctx"))
        for frame in thread.get("stack_frames", [])[:80]:
            print(json.dumps(frame, sort_keys=True))
