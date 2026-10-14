"""Execute production shell entry points against disposable configuration files."""
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class StartupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.config = self.root / "config"
        self.config.mkdir()
        self.defaults = self.root / "defaults"
        self.defaults.mkdir()
        shutil.copy(REPO / "rootfs/defaults/Settings.json", self.defaults / "Settings.json")
        self.tools = self.root / "tools"
        self.tools.mkdir()
        boolean = self.tools / "is-bool-val-true"
        boolean.write_text('#!/bin/sh\ncase "$1" in 1|true|yes|on) exit 0;; *) exit 1;; esac\n')
        boolean.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.tools}:{os.environ['PATH']}")

    def tearDown(self):
        self.temp.cleanup()

    def initialize(self, dark="0"):
        # Only filesystem roots change; jq, traps, copy, and atomic rename are the
        # production script. This runs without access to any real /config mount.
        source = (REPO / "rootfs/etc/cont-init.d/55-vdf.sh").read_text()
        source = source.replace("/config", str(self.config)).replace("/defaults", str(self.defaults))
        return subprocess.run(["sh", "-c", source], env=dict(self.env, DARK_MODE=dark), text=True, capture_output=True)

    def test_default_settings_and_dark_mode(self):
        self.assertEqual(self.initialize("1").returncode, 0)
        settings = json.loads((self.config / "Settings.json").read_text())
        self.assertEqual(settings["Includes"], ["/storage"])
        self.assertTrue(settings["UseNativeFfmpegBinding"])
        self.assertEqual(settings["ThemeMode"], 2)
        self.assertEqual(self.initialize("0").returncode, 0)
        self.assertEqual(json.loads((self.config / "Settings.json").read_text())["ThemeMode"], 1)

    def test_repeated_startup_preserves_new_settings_and_file_mode(self):
        file = self.config / "Settings.json"
        settings = {
            "DarkMode": True, "Includes": ["/storage/example"],
            "EnableScheduledScan": True, "ScheduledScanTime": "23:45",
            "AutomationSelection": {
                "AutoAfterScan": True, "Profile": 0,
                "FolderRules": [{"Directory": "/storage/favourites", "Priority": 1000, "ProtectAll": True}]
            },
            "NfoFavourites": {"Enabled": True, "TagValues": ["Favorite"], "InheritSeries": True},
            "QuarantineFolder": "/storage/quarantine",
            "FutureExtension": {"unknown": [1, 2, 3]}
        }
        file.write_text(json.dumps(settings))
        file.chmod(0o640)
        for dark in ("1", "0", "1"):
            self.assertEqual(self.initialize(dark).returncode, 0)
            result = json.loads(file.read_text())
            expected = dict(settings, ThemeMode=2 if dark == "1" else 1)
            del expected["DarkMode"]
            self.assertEqual(result, expected)
            self.assertEqual(stat.S_IMODE(file.stat().st_mode), 0o640)
        self.assertEqual(list(self.config.glob(".vdf-settings.*")), [])

    def test_malformed_or_nonobject_config_is_not_destroyed(self):
        file = self.config / "Settings.json"
        for original in ("", " \n\t", "{broken", "[]", "null", '"text"', "{}\n{}", "{}\nnull"):
            file.write_text(original)
            self.assertNotEqual(self.initialize().returncode, 0)
            self.assertEqual(file.read_text(), original)
            self.assertEqual(list(self.config.glob(".vdf-settings.*")), [])

    def test_missing_established_settings_are_not_replaced_with_defaults(self):
        for state_name in ("Settings.json.corrupt", "Settings.xml", "ScannedFiles.db", "ReviewedFiles.json.bak", "SelectionPlan.json", "QuarantineHistory.json", "CleanupProtectionPolicy.json.bak", "BlacklistedGroups.json", "backup.scanresults", "log.txt"):
            state = self.config / state_name
            state.write_bytes(b"existing application state")
            result = self.initialize()
            self.assertNotEqual(result.returncode, 0, state_name)
            self.assertFalse((self.config / "Settings.json").exists())
            self.assertEqual(state.read_bytes(), b"existing application state")
            state.unlink()

    def test_missing_settings_after_a_successful_start_fail_closed(self):
        self.assertEqual(self.initialize().returncode, 0)
        (self.config / "Settings.json").unlink()
        self.assertNotEqual(self.initialize().returncode, 0)
        self.assertFalse((self.config / "Settings.json").exists())

    def test_launch_passes_persistent_settings_and_cache_paths(self):
        storage = self.root / "storage"
        storage.mkdir()
        fake_app = self.tools / "VDF.GUI"
        fake_app.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\npwd\nprintenv DOTNET_RUNNING_IN_CONTAINER XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME TMPDIR\n')
        fake_app.chmod(0o755)
        source = (REPO / "rootfs/startapp.sh").read_text()
        source = source.replace("/config", str(self.config)).replace("/storage", str(storage)).replace("/opt/vdf/VDF.GUI", str(fake_app))
        result = subprocess.run(["sh", "-c", source], env=self.env, text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout.splitlines(), [
            "--settings", str(self.config / "Settings.json"), str(storage), "true",
            str(self.config / ".config"), str(self.config / ".local/state"),
            str(self.config / ".cache"), str(self.config / ".cache/vdf/tmp")
        ])
        self.assertTrue((self.config / ".cache/vdf/tmp").is_dir())

    def test_source_builder_rejects_mutable_or_missing_revision(self):
        script = REPO / "src/vdf/build.sh"
        for revision in ("", "main", "v4.1.1", "abc123", "A" * 40, "a" * 40 + "\n", "a" * 40 + "\ninjected=true"):
            result = subprocess.run([str(script), "https://example.invalid/archive.tar.gz", "4.1.1", revision, "10.0.401"], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("full, lowercase application commit SHA", result.stdout)

    def test_ffmpeg_builder_requires_a_source_hash(self):
        for source_hash in ("", "a" * 63, "LATEST", "A" * 64, "a" * 64 + "\n", "a" * 64 + "\ninjected=true"):
            result = subprocess.run([str(REPO / "src/ffmpeg/build.sh"), "https://example.invalid/ffmpeg.tar.xz", source_hash], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("pinned FFmpeg source SHA256", result.stdout)


if __name__ == "__main__":
    unittest.main()
