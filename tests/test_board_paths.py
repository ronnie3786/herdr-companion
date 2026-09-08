"""Run the browser-independent ticket path interaction regression suite."""

import shutil
import subprocess
import unittest
from pathlib import Path


class BoardPathTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("node"), "Node.js is required for board interaction tests")
    def test_ticket_path_interactions(self):
        result = subprocess.run(
            ["node", "--test", str(Path(__file__).with_name("board_paths.test.cjs"))],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
