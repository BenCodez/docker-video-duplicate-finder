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
            (root / "pristine-config").mkdir()
            (root / "pristine-config/Settings.json").write_text('{"pristine":true}\n')
            tools = root / "tools"
            tools.mkdir()
            docker = tools / "docker"
            docker.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$MOCK_TRACE"
case "$1" in
  run)
    for ARG do
      case "$ARG" in */diagnostic-config-*:/config:rw)
        printf '{"changed":true}\\n' > "${ARG%:/config:rw}/Settings.json";;
      esac
    done;;
  inspect) printf 'false\\n';;
  logs|rm|exec) :;;
  *) exit 99;;
esac
''')
            docker.chmod(0o755)
            for name in ("sudo", "dmesg"):
                executable = tools / name
                executable.write_text('#!/bin/sh\nprintf "mock kernel diagnostic\\n"\n')
                executable.chmod(0o755)
            trace = root / "trace"
            env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                       MOCK_TRACE=str(trace), MOCK_ROOT=str(root))
            result = subprocess.run(["sh", str(REPO / "tests/diagnose-gui.sh"),
                                     "test-image", "linux/arm64", str(root), "test-container", "1001", "1001"],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(settings.read_text(), '{"fixture":true}\n')
            self.assertEqual((root / "pristine-config/Settings.json").read_text(), '{"pristine":true}\n')
            for scenario in ("post-crash", "pristine", "pristine-report"):
                self.assertEqual((root / f"diagnostic-config-{scenario}/Settings.json").read_text(),
                                 '{"changed":true}\n')
            calls = trace.read_text().splitlines()
            runs = [call for call in calls if call.startswith("run ")]
            self.assertEqual(len(runs), 3)
            for run in runs:
                self.assertIn("--platform linux/arm64", run)
                self.assertIn(f"{root}/media:/storage:ro", run)
            for run in runs[:2]:
                self.assertNotIn("--cap-add", run)
                self.assertNotIn("DOTNET_DbgEnableMiniDump", run)
                self.assertNotIn("--entrypoint", run)
            self.assertIn("--entrypoint /bin/sh", runs[2])
            self.assertIn("chmod a+x /opt/vdf/createdump && exec /init", runs[2])
            self.assertEqual(calls[-1], "rm -f test-container-diagnostic-pristine-report")

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
