"""Exercise the font ABI gate with real exported and missing ELF functions."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SYMBOLS = REPO / "src/vdf/harfbuzz-8.3.1.3-symbols.txt"


class HarfBuzzRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.app = self.root / "app"
        self.app.mkdir()
        self.deps = self.app / "VDF.GUI.deps.json"
        self.deps.write_text(json.dumps({"libraries": {"HarfBuzzSharp/8.3.1.3": {}}}))
        self.bundled = self.app / "libHarfBuzzSharp.so"
        self.bundled.write_bytes(b"original bundled library")
        self.native = self.root / "libharfbuzz.so.0"

    def tearDown(self):
        self.temp.cleanup()

    def build_exports(self, symbols):
        source = self.root / "exports.c"
        source.write_text("\n".join(f"void {symbol}(void) {{}}" for symbol in symbols))
        subprocess.run(["gcc", "-shared", "-fPIC", str(source), "-o", str(self.native)],
                       check=True, capture_output=True)

    def select(self, inventory=SYMBOLS):
        return subprocess.run(["sh", str(REPO / "src/vdf/use-system-harfbuzz.sh"),
                               str(self.app), str(self.native), str(inventory)],
                              text=True, capture_output=True)

    def assert_unchanged(self):
        self.assertFalse(self.bundled.is_symlink())
        self.assertEqual(self.bundled.read_bytes(), b"original bundled library")
        self.assertFalse((self.app / "NativeFontRuntime.txt").exists())

    def test_selects_one_system_library_after_all_imports_resolve(self):
        symbols = SYMBOLS.read_text().splitlines()
        self.assertEqual(len(symbols), len(set(symbols)))
        self.build_exports(symbols)
        result = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.bundled.resolve(), self.native)
        self.assertIn("Verified C imports: 319", (self.app / "NativeFontRuntime.txt").read_text())

    def test_missing_c_import_preserves_the_bundled_library(self):
        symbols = SYMBOLS.read_text().splitlines()
        self.build_exports(symbols[1:])
        result = self.select()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing HarfBuzz C ABI symbol: " + symbols[0], result.stderr)
        self.assert_unchanged()

    def test_a_different_managed_version_cannot_use_the_inventory(self):
        self.build_exports(SYMBOLS.read_text().splitlines())
        self.deps.write_text(json.dumps({"libraries": {"HarfBuzzSharp/9.0.0": {}}}))
        self.assertNotEqual(self.select().returncode, 0)
        self.assert_unchanged()

    def test_missing_or_non_elf_library_cannot_pass(self):
        self.assertNotEqual(self.select().returncode, 0)
        self.assert_unchanged()
        self.native.write_text("not ELF")
        self.assertNotEqual(self.select().returncode, 0)
        self.assert_unchanged()

    def test_empty_exports_or_truncated_inventory_cannot_pass(self):
        self.build_exports(["unrelated_symbol"])
        self.assertNotEqual(self.select().returncode, 0)
        self.assert_unchanged()
        self.build_exports([])
        self.assertNotEqual(self.select().returncode, 0)
        self.assert_unchanged()
        inventory = self.root / "truncated.txt"
        inventory.write_text("hb_font_create\n")
        self.assertNotEqual(self.select(inventory).returncode, 0)
        self.assert_unchanged()


if __name__ == "__main__":
    unittest.main()
