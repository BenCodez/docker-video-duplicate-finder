"""Print bounded native/managed frames from .NET's synthetic CI crash report."""
import json
from pathlib import Path
import sys

reports = sorted(Path(sys.argv[1]).glob("gui-startup.*.crashreport.json"))
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
