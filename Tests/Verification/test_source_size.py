import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))
import check_source_size


class SourceSizeTests(unittest.TestCase):
    def test_swift_and_cloud_production_files_share_the_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            production = ["Sources/CodexKit/Example.swift", "packages/codexkit/src/client.ts",
                          "packages/codexkit/examples/api-route.ts", "packages/codexkit/scripts/test-package.cjs"]
            excluded = ["packages/codexkit/dist/client.js", "packages/codexkit/dist/client.d.ts",
                        "packages/codexkit/node_modules/vendor/index.js", "packages/codexkit/test/example.test.cjs"]
            for name in production + excluded:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("// line\n" * (600 if name in production else 601))
            with patch.object(check_source_size, "ROOT", root):
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    self.assertEqual(check_source_size.main(), 0)
                self.assertIn("4 production files", output.getvalue())
                for name in production:
                    with self.subTest(path=name):
                        path = root / name
                        path.write_text("// line\n" * 601)
                        with contextlib.redirect_stderr(io.StringIO()) as errors:
                            self.assertEqual(check_source_size.main(), 1)
                        self.assertIn(name + ": 601 physical lines", errors.getvalue())
                        path.write_text("// line\n" * 600)
