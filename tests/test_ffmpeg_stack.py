"""Check the stack gate against actual linked executables and shared libraries."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class FFmpegStackTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "probe.c"
        self.source.write_text("int main(void) { return 0; }\n")

    def tearDown(self):
        self.temp.cleanup()

    def link(self, name, stack_size=None, shared=False):
        output = self.root / name
        command = ["gcc", str(self.source), "-o", str(output)]
        if shared:
            command += ["-shared", "-fPIC"]
        if stack_size is not None:
            command += [f"-Wl,-z,stack-size={stack_size}"]
        subprocess.run(command, check=True, capture_output=True, text=True)
        return output

    def check(self, *files):
        return subprocess.run(["sh", str(REPO / "src/ffmpeg/check-stack.sh"),
                               *(str(file) for file in files)],
                              text=True, capture_output=True)

    def test_accepts_tools_and_shared_libraries_with_two_mib(self):
        files = [self.link("tool", 2097152),
                 self.link("codec.so", 2097152, shared=True)]
        result = self.check(*files)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("Verified PT_GNU_STACK:"), 2)
        self.assertEqual(result.stdout.count("2097152 bytes"), 2)

    def test_rejects_default_stack_in_executables_and_shared_libraries(self):
        for shared in (False, True):
            with self.subTest(shared=shared):
                file = self.link(f"default-{shared}", shared=shared)
                result = self.check(file)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("needs a PT_GNU_STACK reservation", result.stderr)

    def test_rejects_one_undersized_file_in_an_otherwise_valid_set(self):
        valid = self.link("tool", 2097152)
        invalid = self.link("codec.so", 131072, shared=True)
        result = self.check(valid, invalid)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(invalid), result.stderr)
        self.assertIn("0x020000", result.stderr)

    def test_missing_non_elf_or_empty_input_cannot_pass(self):
        non_elf = self.root / "not-an-elf"
        non_elf.write_text("invalid ELF\n")
        for files in ([], [self.root / "missing"], [non_elf]):
            with self.subTest(files=files):
                self.assertNotEqual(self.check(*files).returncode, 0)


if __name__ == "__main__":
    unittest.main()
