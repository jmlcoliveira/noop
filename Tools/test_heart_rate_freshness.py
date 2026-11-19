"""Compile and exercise the production, Foundation-only live-HR freshness state."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "Strand" / "BLE" / "HeartRateFreshness.swift"


HARNESS = r'''import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

func expectReschedule(_ action: HeartRateFreshness.TimerAction, _ seconds: TimeInterval, _ label: String) {
    guard case .reschedule(let actual) = action else {
        fatalError("\(label): expected reschedule, got \(action)")
    }
    expect(abs(actual - seconds) < 0.000_001,
           "\(label): expected \(seconds) seconds remaining, got \(actual)")
}

func testEveryReadableSampleIsRecordedBeforeTimerThrottle() {
    var freshness = HeartRateFreshness()
    let firstDate = Date(timeIntervalSince1970: 100)
    let secondDate = Date(timeIntervalSince1970: 90) // Wall time moved backward.
    expect(freshness.recordReadableSample(at: firstDate, monotonicTime: 0, silenceInterval: 10) == 10,
           "first sample should arm the silence timer")
    expect(freshness.recordReadableSample(at: secondDate, monotonicTime: 0.5, silenceInterval: 10) == nil,
           "sample inside rearm throttle should not reschedule")
    expect(freshness.lastReadableAt == secondDate,
           "throttled sample must still update the non-publishing wall-clock timestamp")
    expectReschedule(freshness.timerFired(monotonicTime: 1, silenceInterval: 10), 9.5,
                     "backward wall-clock change")
}

func testEarlyTimerReschedulesOnlyRemainingSilence() {
    var freshness = HeartRateFreshness()
    _ = freshness.recordReadableSample(at: Date(timeIntervalSince1970: 0), monotonicTime: 20,
                                       silenceInterval: 10)
    expectReschedule(freshness.timerFired(monotonicTime: 23, silenceInterval: 10), 7,
                     "early timer callback")
}

func testFreshBoundaryAndStaleBoundary() {
    var freshness = HeartRateFreshness()
    _ = freshness.recordReadableSample(at: Date(timeIntervalSince1970: 0), monotonicTime: 1,
                                       silenceInterval: 10)
    expectReschedule(freshness.timerFired(monotonicTime: 10.999, silenceInterval: 10), 0.001,
                     "just before freshness boundary")
    expect(freshness.timerFired(monotonicTime: 11, silenceInterval: 10) == .clearHeartRate,
           "sample must be stale at the exact silence boundary")
    expect(freshness.recordReadableSample(at: Date(timeIntervalSince1970: 1), monotonicTime: 12,
                                          silenceInterval: 10) == 10,
           "a stale timer firing must release its rearm throttle")
}

func testLateCallbackCannotClearAReadingArrivedDuringThrottle() {
    var freshness = HeartRateFreshness()
    _ = freshness.recordReadableSample(at: Date(timeIntervalSince1970: 0), monotonicTime: 0,
                                       silenceInterval: 10)
    expect(freshness.recordReadableSample(at: Date(timeIntervalSince1970: 1), monotonicTime: 9.5,
                                          silenceInterval: 10) == 10,
           "new sample after throttle should rearm the ordinary timer")
    expectReschedule(freshness.timerFired(monotonicTime: 10, silenceInterval: 10), 9.5,
                     "old callback after newer sample")

    var throttled = HeartRateFreshness()
    _ = throttled.recordReadableSample(at: Date(timeIntervalSince1970: 0), monotonicTime: 0,
                                       silenceInterval: 10)
    expect(throttled.recordReadableSample(at: Date(timeIntervalSince1970: 1), monotonicTime: 0.5,
                                          silenceInterval: 10) == nil,
           "new sample should remain throttled")
    expectReschedule(throttled.timerFired(monotonicTime: 10, silenceInterval: 10), 0.5,
                     "old callback after throttled newer sample")
}

func testForwardWallClockJumpDoesNotChangeMonotonicFreshness() {
    var freshness = HeartRateFreshness()
    _ = freshness.recordReadableSample(at: Date(timeIntervalSince1970: 100), monotonicTime: 50,
                                       silenceInterval: 10)
    let jumpedWallDate = Date(timeIntervalSince1970: 1_000_000)
    _ = freshness.recordReadableSample(at: jumpedWallDate, monotonicTime: 54,
                                       silenceInterval: 10)
    expect(freshness.lastReadableAt == jumpedWallDate, "public timestamp should reflect latest wall time")
    expectReschedule(freshness.timerFired(monotonicTime: 55, silenceInterval: 10), 9,
                     "forward wall-clock change")
}

func testSourceResetClearsTimestampAndRejectsOldTimerCallback() {
    var freshness = HeartRateFreshness()
    _ = freshness.recordReadableSample(at: Date(timeIntervalSince1970: 100), monotonicTime: 200,
                                       silenceInterval: 10)
    freshness.reset()
    expect(freshness.lastReadableAt == nil, "source reset must clear the exposed timestamp")
    expect(freshness.timerFired(monotonicTime: 500, silenceInterval: 10) == .noReadableSample,
           "old callback after reset must not clear a value")

    _ = freshness.recordReadableSample(at: Date(timeIntervalSince1970: 10), monotonicTime: 500,
                                       silenceInterval: 10)
    expectReschedule(freshness.timerFired(monotonicTime: 501, silenceInterval: 10), 9,
                     "new source session after reset")
}

testEveryReadableSampleIsRecordedBeforeTimerThrottle()
testEarlyTimerReschedulesOnlyRemainingSilence()
testFreshBoundaryAndStaleBoundary()
testLateCallbackCannotClearAReadingArrivedDuringThrottle()
testForwardWallClockJumpDoesNotChangeMonotonicFreshness()
testSourceResetClearsTimestampAndRejectsOldTimerCallback()
print("heart-rate freshness checks passed (6 scenarios)")
'''


class HeartRateFreshnessTests(unittest.TestCase):
    def test_production_freshness_state(self) -> None:
        swiftc = shutil.which("swiftc")
        if swiftc is None:
            self.skipTest("swiftc is unavailable; production Swift freshness test skipped")

        with tempfile.TemporaryDirectory(prefix="noop-heart-rate-freshness-") as temp_dir:
            temp = Path(temp_dir)
            module_cache = temp / "module-cache"
            module_cache.mkdir()
            harness = temp / "main.swift"
            executable = temp / "heart-rate-freshness-checks"
            harness.write_text(HARNESS, encoding="utf-8")
            env = os.environ.copy()

            compile_result = subprocess.run(
                [swiftc, "-module-cache-path", str(module_cache), str(HELPER), str(harness),
                 "-o", str(executable)],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
                env=env,
                timeout=90,
            )
            self.assertEqual(
                compile_result.returncode,
                0,
                msg=f"swiftc failed:\n{compile_result.stdout}\n{compile_result.stderr}",
            )

            run_result = subprocess.run(
                [str(executable)],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
                env=env,
                timeout=30,
            )
            self.assertEqual(
                run_result.returncode,
                0,
                msg=f"freshness checks failed:\n{run_result.stdout}\n{run_result.stderr}",
            )
            self.assertIn("heart-rate freshness checks passed (6 scenarios)", run_result.stdout)


if __name__ == "__main__":
    unittest.main()
