"""Execute the native fixture helper and verify failures remain release gates."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class NativeDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.media = self.root / "media"
        self.media.mkdir()
        tools = self.root / "tools"
        tools.mkdir()
        self.tools = tools
        ffmpeg = tools / "ffmpeg"
        ffmpeg.write_text('''#!/bin/sh
printf 'ffmpeg %s\\n' "$*" >> "$MOCK_TRACE"
case "$*" in
  *-version*) printf 'mock FFmpeg version\\n'; exit "${MOCK_VERSION_EXIT:-0}";;
  *'-v debug'*) STATUS="${MOCK_DEBUG_EXIT:-${MOCK_ENCODE_EXIT:-0}}";;
  *) STATUS="${MOCK_ENCODE_EXIT:-0}";;
esac
[ "$STATUS" = 0 ] || exit "$STATUS"
for OUTPUT do :; done
printf 'synthetic video\\n' > "$OUTPUT"
''')
        for name in ("ffprobe", "ffplay", "ldd", "gdb"):
            file = tools / name
            file.write_text(f'#!/bin/sh\nprintf \'{name} %s\\n\' "$*" >> "$MOCK_TRACE"\nprintf \'mock {name} diagnostics\\n\'\n')
        for file in tools.iterdir():
            file.chmod(0o755)
        self.trace = self.root / "trace"
        self.env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                        MOCK_TRACE=str(self.trace), LD_PRELOAD="")

    def tearDown(self):
        self.temp.cleanup()

    def run_helper(self, **env):
        return subprocess.run(["sh", str(REPO / "tests/prepare-fixture.sh"), str(self.media)],
                              env=dict(self.env, **env), text=True, capture_output=True)

    def test_diagnostics_precede_the_original_fixture_encode(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        trace = self.trace.read_text().splitlines()
        self.assertTrue(all(line.startswith("ldd ") for line in trace[:3]))
        self.assertEqual(trace[3:5], ["ffmpeg -hide_banner -version", "ffprobe -hide_banner -version"])
        self.assertIn("-f lavfi -i testsrc=size=160x90:rate=5 -t 2 -c:v ffv1", trace[5])
        self.assertIn("-nostdin", trace[5])
        self.assertIn("LD_LIBRARY_PATH=", result.stdout)
        self.assertIn("LD_PRELOAD=", result.stdout)
        self.assertEqual((self.media / "example-a.mkv").read_bytes(), (self.media / "example-b.mkv").read_bytes())
        self.assertEqual((self.media / "example-a.nfo").read_text(), "<movie><tag>Favorite</tag></movie>\n")

    def test_version_failure_stops_before_fixture_creation(self):
        result = self.run_helper(MOCK_VERSION_EXIT="139")
        self.assertEqual(result.returncode, 139)
        self.assertEqual(len(self.trace.read_text().splitlines()), 4)
        self.assertFalse(list(self.media.iterdir()))

    def test_encode_failure_preserves_the_exit_status_without_a_fallback(self):
        result = self.run_helper(MOCK_ENCODE_EXIT="139")
        self.assertEqual(result.returncode, 139)
        trace = self.trace.read_text().splitlines()
        self.assertEqual(len(trace), 8)
        self.assertIn("-v debug", trace[6])
        self.assertTrue(trace[7].startswith("gdb --batch "))
        self.assertFalse(list(self.media.iterdir()))

    def test_successful_diagnostic_retry_cannot_replace_the_failed_encode(self):
        result = self.run_helper(MOCK_ENCODE_EXIT="139", MOCK_DEBUG_EXIT="0")
        self.assertEqual(result.returncode, 139)
        self.assertTrue((self.media / "diagnostic-encode.mkv").exists())
        self.assertFalse((self.media / "example-a.mkv").exists())
        self.assertFalse((self.media / "example-b.mkv").exists())
        self.assertFalse((self.media / "example-a.nfo").exists())

    def test_image_smoke_forwards_helper_stdin_and_stops_on_native_failure(self):
        docker = self.tools / "docker"
        docker.write_text('''#!/bin/sh
case "$1" in
  run)
    INTERACTIVE=false
    for ARG do [ "$ARG" != --interactive ] || INTERACTIVE=true; done
    [ "$INTERACTIVE" = true ] || exit 98
    cat > "$MOCK_DOCKER_STDIN"
    exec sh "$MOCK_DOCKER_STDIN" "$MOCK_MEDIA"
    ;;
  logs|rm) exit 0;;
  *) exit 99;;
esac
''')
        docker.chmod(0o755)
        captured = self.root / "container-stdin"
        env = dict(self.env, MOCK_VERSION_EXIT="139", MOCK_DOCKER_STDIN=str(captured),
                   MOCK_MEDIA=str(self.media))
        result = subprocess.run(["sh", str(REPO / "tests/smoke-image.sh"), "test-image"],
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 139, result.stderr)
        self.assertEqual(captured.read_bytes(), (REPO / "tests/prepare-fixture.sh").read_bytes())
        self.assertFalse(list(self.media.iterdir()))

    def test_successful_gui_diagnostics_cannot_replace_the_original_smoke_failure(self):
        docker = self.tools / "docker"
        docker.write_text('''#!/bin/sh
printf 'docker %s\\n' "$*" >> "$MOCK_TRACE"
case "$1" in
  run)
    case " $* " in
      *' --interactive '*) cat > "$MOCK_DOCKER_STDIN"; exec sh "$MOCK_DOCKER_STDIN" "$MOCK_MEDIA";;
      *)
        for ARG do
          case "$ARG" in */config:/config:rw)
            ROOT="${ARG%/config:/config:rw}"
            cmp "$ROOT/config/Settings.json" "$ROOT/pristine-config/Settings.json" || exit 97
            cmp "$ROOT/config/ScannedFiles.db" "$ROOT/pristine-config/ScannedFiles.db" || exit 97
            printf 'pristine fixture captured\\n' >> "$MOCK_TRACE";;
          esac
        done
        exit 0;;
    esac
    ;;
  inspect)
    [ "$2" != -f ] || printf 'false\\n'
    exit 0;;
  logs|rm|stop|exec) exit 0;;
  *) exit 99;;
esac
''')
        docker.chmod(0o755)
        captured = self.root / "container-stdin"
        env = dict(self.env, MOCK_DOCKER_STDIN=str(captured), MOCK_MEDIA=str(self.media))
        result = subprocess.run(["sh", str(REPO / "tests/smoke-image.sh"), "test-image"],
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Container exited before scheduled scan", result.stdout)
        trace = self.trace.read_text().splitlines()
        gui_runs = [line for line in trace if line.startswith("docker run -d ")]
        self.assertEqual(len(gui_runs), 4)
        self.assertIn("pristine fixture captured", trace)
        for run in gui_runs[:3]:
            self.assertNotIn("--cap-add", run)
            self.assertNotIn("DOTNET_EnableCrashReportOnly", run)
        self.assertIn("--cap-add=SYS_PTRACE", gui_runs[3])
        self.assertIn("DOTNET_EnableCrashReportOnly=1", gui_runs[3])
        self.assertIn("/diagnostic-config-pristine-report:/config:rw", gui_runs[3])
        self.assertNotIn("--rm", gui_runs[3])


if __name__ == "__main__":
    unittest.main()
