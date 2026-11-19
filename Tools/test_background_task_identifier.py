"""Exercise the production identifier resolver used by iOS background schedulers."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "Strand" / "System" / "BackgroundTaskIdentifier.swift"
SWIFT = shutil.which("swiftc")

HARNESS = r'''import Foundation
func expect(_ actual: String, _ expected: String) {
    precondition(actual == expected, "expected \(expected), got \(actual)")
}
let original = "dev.pulse.companion.noop"
let resigned = original + ".TESTTEAM01"
let tasks = ["debugexport", "coachbrief", "healthwriteback", "rescore", "stalebattery"]
let permitted = tasks.map { original + "." + $0 }
for task in tasks {
    let expected = original + "." + task
    expect(BackgroundTaskIdentifier.resolve(task, permitted: permitted, bundleIdentifier: original), expected)
    expect(BackgroundTaskIdentifier.resolve(task, permitted: permitted, bundleIdentifier: resigned), expected)
}
let alternatives = permitted + tasks.map { resigned + "." + $0 }
expect(BackgroundTaskIdentifier.resolve("rescore", permitted: alternatives, bundleIdentifier: resigned), resigned + ".rescore")
expect(BackgroundTaskIdentifier.resolve("healthwriteback", permitted: [], bundleIdentifier: original), original + ".healthwriteback")
expect(BackgroundTaskIdentifier.resolve("coachbrief", permitted: [], bundleIdentifier: nil), "com.noopapp.noop.coachbrief")
expect(BackgroundTaskIdentifier.resolve("rescore", permitted: ["a.notrescore", "b.rescore", "a.rescore"], bundleIdentifier: resigned), "a.rescore")
expect(BackgroundTaskIdentifier.resolve("rescore", permitted: ["a.notrescore"], bundleIdentifier: original), original + ".rescore")
print("background task identifier checks passed (15 cases)")
'''


@unittest.skipUnless(SWIFT, "swiftc is unavailable")
class BackgroundTaskIdentifierTests(unittest.TestCase):
    def test_resigned_bundle_keeps_declared_background_tasks(self):
        with tempfile.TemporaryDirectory(prefix="pulse-background-identifier-") as folder:
            path = Path(folder)
            source = path / "main.swift"
            source.write_text(HARNESS)
            binary = path / "checks"
            result = subprocess.run(
                [SWIFT, "-module-cache-path", str(path / "modules"), str(HELPER), str(source), "-o", str(binary)],
                capture_output=True, text=True, timeout=90, env=os.environ.copy(),
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("checks passed (15 cases)", run.stdout)


if __name__ == "__main__":
    unittest.main()
