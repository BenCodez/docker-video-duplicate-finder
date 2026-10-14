"""Exercise failure-only configuration isolation and .NET frame reporting."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class GUIDiagnosticsTests(unittest.TestCase):
    def test_diagnostic_replay_keeps_the_original_config_and_removes_its_container(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "config").mkdir()
            settings = root / "config/Settings.json"
            settings.write_text('{"fixture":true}\n')
            (root / "media").mkdir()
            tools = root / "tools"
            tools.mkdir()
            docker = tools / "docker"
            docker.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$MOCK_TRACE"
case "$1" in
  run) printf 'changed by diagnostic replay\\n' > "$MOCK_ROOT/diagnostic-config/Settings.json";;
  inspect) printf 'false\\n';;
  logs|rm) :;;
  *) exit 99;;
esac
''')
            docker.chmod(0o755)
            trace = root / "trace"
            env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                       MOCK_TRACE=str(trace), MOCK_ROOT=str(root))
            result = subprocess.run(["sh", str(REPO / "tests/diagnose-gui.sh"),
                                     "test-image", "linux/arm64", str(root), "test-container", "1001", "1001"],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(settings.read_text(), '{"fixture":true}\n')
            self.assertEqual((root / "diagnostic-config/Settings.json").read_text(),
                             "changed by diagnostic replay\n")
            calls = trace.read_text().splitlines()
            self.assertIn("--platform linux/arm64", calls[0])
            self.assertIn(f"{root}/media:/storage:ro", calls[0])
            self.assertIn("--entrypoint /bin/sh", calls[0])
            self.assertIn("chmod a+x /opt/vdf/createdump && exec /init", calls[0])
            self.assertEqual(calls[-1], "rm -f test-container-diagnostic")

    def test_report_prioritizes_crashed_threads_and_limits_printed_frames(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            report = {"payload": {"process_name": "VDF.GUI", "threads": [
                {"native_thread_id": "2", "crashed": False, "stack_frames": [{"method_name": "other"}]},
                {"native_thread_id": "1", "crashed": True,
                 "stack_frames": [{"native_module": "native.so", "native_offset": str(i)} for i in range(100)]}
            ]}, "parameters": {"ExceptionType": "SIGSEGV"}}
            (root / "gui-startup.42.crashreport.json").write_text(json.dumps(report))
            result = subprocess.run(["python3", str(REPO / "tests/print-crash-report.py"), str(root)],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("SIGSEGV", result.stdout)
            self.assertLess(result.stdout.index("Thread: 1"), result.stdout.index("Thread: 2"))
            self.assertEqual(result.stdout.count('"native_module": "native.so"'), 80)
            self.assertIn('"method_name": "other"', result.stdout)


if __name__ == "__main__":
    unittest.main()
