"""Compile and exercise the pure Swift HealthKit workout sport alias resolver."""

from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER = REPO_ROOT / "Strand/Data/HealthKitWorkoutSportAlias.swift"
SWIFT = shutil.which("swiftc")


class HealthKitWorkoutSportAliasTests(unittest.TestCase):
    @unittest.skipUnless(SWIFT, "swiftc is unavailable; Swift helper regression test skipped")
    def test_real_swift_helper_maps_sports_for_healthkit_export(self) -> None:
        """Run the actual product helper without HealthKit or an app target."""
        assert SWIFT is not None
        with tempfile.TemporaryDirectory(prefix="healthkit-sport-alias-") as temp_dir:
            temp = Path(temp_dir)
            module_cache = temp / "module-cache"
            module_cache.mkdir()
            harness = temp / "main.swift"
            binary = temp / "sport-alias-test"
            harness.write_text(
                '''import Foundation

let cases: [(String, HealthKitWorkoutSportAlias?)] = [
    ("Stair climber", .stairClimbing),
    ("stair climber", .stairClimbing),
    ("  Stair climber\\t", .stairClimbing),
    ("StairMaster", .stairClimbing),
    ("STAIR MASTER", .stairClimbing),
    ("Stair-stepper", .stairClimbing),
    ("Stair stepper", .stairClimbing),
    ("Stair climbing machine", .stairClimbing),
    ("Strength", .traditionalStrengthTraining),
    ("strength", .traditionalStrengthTraining),
    ("Strength Training", .traditionalStrengthTraining),
    (" strength-training ", .traditionalStrengthTraining),
    ("Weightlifting", .traditionalStrengthTraining),
    ("Powerlifting", .traditionalStrengthTraining),
    ("Bodybuilding", .traditionalStrengthTraining),
    ("Other", nil),
    ("user-defined activity", nil),
    ("", nil),
]

for (label, expected) in cases {
    let actual = HealthKitWorkoutSportAlias.resolve(label)
    guard actual == expected else {
        fatalError("\\(label.debugDescription): expected \\(String(describing: expected)), got \\(String(describing: actual))")
    }
}
print("\\(cases.count) HealthKit sport alias cases passed")
''',
                encoding="utf-8",
            )

            compile = subprocess.run(
                [
                    SWIFT,
                    "-module-cache-path",
                    str(module_cache),
                    str(HELPER),
                    str(harness),
                    "-o",
                    str(binary),
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(compile.returncode, 0, compile.stdout + compile.stderr)

            run = subprocess.run(
                [str(binary)], cwd=REPO_ROOT, capture_output=True, text=True, check=False
            )
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertEqual("18 HealthKit sport alias cases passed", run.stdout.strip())


if __name__ == "__main__":
    unittest.main()
