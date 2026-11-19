"""Compile and exercise the production re-score queue, policy, and scheduler."""

from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    ROOT / "Strand/Data/RescoreBackgroundPolicy.swift",
    ROOT / "Strand/System/RescoreBackgroundScheduler.swift",
    ROOT / "Tools/rescore_follow_up_harness.swift",
]


class RescoreFollowUpTests(unittest.TestCase):
    def test_production_queue_policy_and_scheduler(self) -> None:
        xcrun = shutil.which("xcrun")
        if xcrun is None:
            self.skipTest("xcrun is required to compile the production Swift helpers")

        with tempfile.TemporaryDirectory(prefix="noop-rescore-follow-up-") as temp_dir:
            temp = Path(temp_dir)
            executable = temp / "rescore-follow-up-checks"
            module_cache = temp / "module-cache"
            module_cache.mkdir()
            compile_result = subprocess.run(
                [xcrun, "swiftc", "-module-cache-path", str(module_cache),
                 *(str(source) for source in SOURCES), "-o", str(executable)],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                compile_result.returncode,
                0,
                msg=f"swiftc failed:\n{compile_result.stdout}\n{compile_result.stderr}",
            )

            run_result = subprocess.run(
                [str(executable)], cwd=ROOT, check=False, capture_output=True, text=True
            )
            self.assertEqual(
                run_result.returncode,
                0,
                msg=f"runtime checks failed:\n{run_result.stdout}\n{run_result.stderr}",
            )
            self.assertIn("rescore follow-up checks passed", run_result.stdout)


if __name__ == "__main__":
    unittest.main()
