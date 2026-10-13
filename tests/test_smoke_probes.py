"""Check that the shipped restart probe rejects an unchanged, rewritten ledger."""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SMOKE = (REPO / "tests/smoke-image.sh").read_text()


class SmokeProbeTests(unittest.TestCase):
    def test_embedded_python_blocks_have_valid_syntax(self):
        blocks = re.findall(r"<<'PY'\n(.*?)\nPY", SMOKE, re.DOTALL)
        self.assertTrue(blocks)
        for block in blocks:
            compile(block, "smoke-image.sh", "exec")

    def test_restart_probe_requires_both_gui_rows_to_be_processed(self):
        probe = re.search(r"reviews_refreshed\(\) \{.*?<<'PY'\n(.*?)\nPY", SMOKE, re.DOTALL).group(1)
        records = [{"identity": {"path": f"/storage/example-{name}.mkv"},
                    "updatedUtc": "2026-10-13T00:00:00Z"} for name in ("a", "b")]
        with tempfile.TemporaryDirectory() as temp:
            before, after = (Path(temp) / name for name in ("before.json", "after.json"))
            before.write_text(json.dumps({"records": records}))
            for refreshed in (0, 1, 2):
                updated = json.loads(json.dumps(records))
                for record in updated[:refreshed]:
                    record["updatedUtc"] = "2026-10-13T00:01:00Z"
                # Rewriting the ledger updates its file timestamp even when no
                # GUI rows were restored. Only per-row processing may pass.
                after.write_text(json.dumps({"records": updated}))
                result = subprocess.run([sys.executable, "-c", probe, str(before), str(after)],
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode == 0, refreshed == 2, result.stderr)


if __name__ == "__main__":
    unittest.main()
