"""Compile and exercise the production, CoreBluetooth-free reconnect-ordering helper."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "Strand" / "BLE" / "BondLoopStandingConnectRecovery.swift"
HARNESS = ROOT / "Tools" / "reconnect_recovery_ordering_harness.swift"


class ReconnectRecoveryOrderingTests(unittest.TestCase):
    def test_production_recovery_orchestration(self) -> None:
        xcrun = shutil.which("xcrun")
        if xcrun is None:
            self.skipTest("xcrun is required to exercise the production Swift helper")

        with tempfile.TemporaryDirectory(prefix="noop-reconnect-recovery-") as temp_dir:
            executable = Path(temp_dir) / "reconnect-recovery-checks"
            module_cache = Path(temp_dir) / "module-cache"
            env = os.environ.copy()
            compile_result = subprocess.run(
                [xcrun, "swiftc", "-module-cache-path", str(module_cache),
                 str(HELPER), str(HARNESS), "-o", str(executable)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(
                compile_result.returncode,
                0,
                msg=f"swiftc failed:\n{compile_result.stdout}\n{compile_result.stderr}",
            )

            run_result = subprocess.run(
                [str(executable)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(
                run_result.returncode,
                0,
                msg=f"runtime checks failed:\n{run_result.stdout}\n{run_result.stderr}",
            )
            self.assertIn("reconnect recovery ordering checks passed", run_result.stdout)


if __name__ == "__main__":
    unittest.main()
