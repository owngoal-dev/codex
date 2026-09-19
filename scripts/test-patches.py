"""Check dependency patch tolerance without downloading upstream or building V8."""
from pathlib import Path
import subprocess
import tempfile
import sys
import unittest

ROOT = Path(__file__).resolve().parent.parent
PATCH = (ROOT / "patches/0002-ios-no-wayland-arboard.patch").read_text()
WORKSPACE_PATCH = PATCH.split("diff --git a/codex-rs/tui/Cargo.toml", 1)[0]
BEFORE = 'arboard = { version = "3", features = ["wayland-data-control"] }'
AFTER = 'arboard = { version = "3" }'


class DependencyPatchTests(unittest.TestCase):
    def apply(self, source, patch_text=WORKSPACE_PATCH):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "--quiet", directory], check=True)
            manifest = root / "codex-rs/Cargo.toml"
            manifest.parent.mkdir()
            if source is not None:
                manifest.write_text(source)
            patch = root / "test.patch"
            patch.write_text(patch_text)
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/apply-patch.py"), str(root), str(patch)],
                text=True,
                cwd=root,
                capture_output=True,
            )
            return result, manifest.read_text()

    def test_unrelated_dependency_changes_and_relocation(self):
        for prefix in ("", "\n" * 400):
            with self.subTest(lines=prefix.count("\n")):
                source = (
                    prefix + '[workspace.dependencies]\nnew-crate = "2"\n'
                    + BEFORE + '\nnext-crate = "999"\n'
                )
                result, actual = self.apply(source)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(actual, source.replace(BEFORE, AFTER))

    def test_new_file_patch(self):
        patch = """diff --git a/codex-rs/Cargo.toml b/codex-rs/Cargo.toml
new file mode 100644
--- /dev/null
+++ b/codex-rs/Cargo.toml
@@ -0,0 +1 @@
+[workspace]
"""
        result, actual = self.apply(None, patch)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(actual, "[workspace]\n")
        result, actual = self.apply(
            BEFORE + "\n",
            WORKSPACE_PATCH + patch.replace("Cargo.toml", "Added.toml"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(actual, AFTER + "\n")

    def test_ambiguous_declaration_fails_without_modifying_source(self):
        source = BEFORE + "\n" + BEFORE + "\n"
        result, actual = self.apply(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("2 matches", result.stderr)
        self.assertEqual(actual, source)

    def test_incompatible_declaration_fails_without_modifying_source(self):
        source = BEFORE.replace('"3"', '"4"') + "\n"
        result, actual = self.apply(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(actual, source)


if __name__ == "__main__":
    unittest.main()
