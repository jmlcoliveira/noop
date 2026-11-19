"""Compile and exercise the production Foundation-only active-energy policy."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "StrandiOS" / "Health" / "PulseActiveEnergyPolicy.swift"
SWIFT = shutil.which("swiftc")


HARNESS = r'''import Foundation

typealias Workout = PulseActiveEnergyPolicy.Workout
typealias Interval = PulseActiveEnergyPolicy.Interval
typealias Span = PulseActiveEnergyPolicy.Span
typealias Bucket = PulseActiveEnergyPolicy.Bucket

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

func close(_ a: Double, _ b: Double, tolerance: Double = 0.000_001) -> Bool {
    abs(a - b) <= tolerance
}

func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

func timestamp(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0,
               _ minute: Int = 0, calendar: Calendar) -> Double {
    calendar.date(from: DateComponents(year: year, month: month, day: day,
                                       hour: hour, minute: minute))!.timeIntervalSince1970
}

func dayKey(_ year: Int, _ month: Int, _ day: Int) -> String {
    String(format: "%04d-%02d-%02d", year, month, day)
}

func testExternalWorkoutBlocksOnlyItsCoverage() {
    let local = [
        Workout(start: 0, end: 600, kcal: 60, priority: 5, stableID: "hevy"),
        Workout(start: 1_200, end: 1_800, kcal: 457.012, priority: 5, stableID: "stairmaster"),
    ]
    let result = PulseActiveEnergyPolicy.supplementalSpans(
        local: local, externalCoverage: [Interval(start: 0, end: 600)],
        from: 0, to: 2_400, calendar: utcCalendar())
    expect(result.count == 1, "Health-covered Hevy workout must not be supplemented")
    expect(close(result[0].kcal, 457.012), "separate StairMaster energy must remain available")
    expect(result[0].start == 1_200 && result[0].end == 1_800,
           "coverage should leave the separate workout's time intact")
}

func testPartialCoverageTrimsOnlyCoveredTimeAndEnergy() {
    let local = [Workout(start: 0, end: 100, kcal: 100, priority: 0, stableID: "local")]
    let result = PulseActiveEnergyPolicy.supplementalSpans(
        local: local, externalCoverage: [Interval(start: 20, end: 40)],
        from: 0, to: 100, calendar: utcCalendar())
    expect(result.count == 2, "partial coverage should preserve both uncovered sides")
    expect(result[0] == Span(start: 0, end: 20, kcal: 20), "left uncovered portion should be prorated")
    expect(result[1] == Span(start: 40, end: 100, kcal: 60), "right uncovered portion should be prorated")
}

func testPriorityAndStableIDResolveLocalDuplicates() {
    let detected = Workout(start: 0, end: 100, kcal: 900, priority: 1, stableID: "detected")
    let manual = Workout(start: 0, end: 100, kcal: 100, priority: 2, stableID: "manual")
    let lowerStableID = Workout(start: 0, end: 100, kcal: 80, priority: 2, stableID: "a")
    let result = PulseActiveEnergyPolicy.supplementalSpans(
        local: [detected, manual, lowerStableID], externalCoverage: [],
        from: 0, to: 100, calendar: utcCalendar())
    expect(result == [Span(start: 0, end: 100, kcal: 80)],
           "highest priority wins and the smaller stable ID breaks ties")
}

func testCrossMidnightSplitsAtLocalDayBoundary() {
    let calendar = utcCalendar()
    let start = timestamp(2024, 1, 1, 23, calendar: calendar)
    let end = timestamp(2024, 1, 2, 1, calendar: calendar)
    let result = PulseActiveEnergyPolicy.supplementalSpans(
        local: [Workout(start: start, end: end, kcal: 200, priority: 0, stableID: "overnight")],
        externalCoverage: [], from: start, to: end, calendar: calendar)
    expect(result == [Span(start: start, end: start + 3_600, kcal: 100),
                      Span(start: start + 3_600, end: end, kcal: 100)],
           "overnight energy must be split evenly at local midnight")
}

func testSpringAndFallDayBoundariesFollowCalendarDST() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!

    let springStart = timestamp(2024, 3, 9, 23, calendar: calendar)
    let springEnd = timestamp(2024, 3, 11, 1, calendar: calendar)
    let spring = PulseActiveEnergyPolicy.supplementalSpans(
        local: [Workout(start: springStart, end: springEnd, kcal: 2_500,
                        priority: 0, stableID: "spring")],
        externalCoverage: [], from: springStart, to: springEnd, calendar: calendar)
    expect(spring.map { $0.end - $0.start } == [3_600, 82_800, 3_600],
           "spring-forward local day must contain 23 hours")
    expect(close(spring[0].kcal, 100) && close(spring[1].kcal, 2_300)
           && close(spring[2].kcal, 100),
           "spring-forward energy must use elapsed time across the 23-hour day")

    let fallStart = timestamp(2024, 11, 2, 23, calendar: calendar)
    let fallEnd = timestamp(2024, 11, 4, 1, calendar: calendar)
    let fall = PulseActiveEnergyPolicy.supplementalSpans(
        local: [Workout(start: fallStart, end: fallEnd, kcal: 2_700,
                        priority: 0, stableID: "fall")],
        externalCoverage: [], from: fallStart, to: fallEnd, calendar: calendar)
    expect(fall.map { $0.end - $0.start } == [3_600, 90_000, 3_600],
           "fall-back local day must contain 25 hours")
    expect(close(fall[0].kcal, 100) && close(fall[1].kcal, 2_500) && close(fall[2].kcal, 100),
           "fall-back energy must use elapsed time across the 25-hour day")
}

func testClippingInvalidValuesAndTouchingWorkouts() {
    let values = [
        Workout(start: 0, end: 100, kcal: 100, priority: 0, stableID: "clipped"),
        Workout(start: 1, end: 1, kcal: 100, priority: 1, stableID: "zero-duration"),
        Workout(start: 0, end: 100, kcal: 0, priority: 1, stableID: "zero-energy"),
        Workout(start: 0, end: 100, kcal: .nan, priority: 1, stableID: "nan"),
        Workout(start: .infinity, end: 200, kcal: 10, priority: 1, stableID: "infinite-time"),
        Workout(start: 50, end: 40, kcal: 10, priority: 1, stableID: "reversed"),
        Workout(start: 100, end: 110, kcal: 10, priority: 0, stableID: "touching"),
    ]
    let result = PulseActiveEnergyPolicy.supplementalSpans(
        local: values, externalCoverage: [Interval(start: .nan, end: 30)],
        from: 20, to: 110, calendar: utcCalendar())
    expect(result.count == 2, "invalid inputs are ignored and touching intervals stay separate")
    expect(result[0] == Span(start: 20, end: 100, kcal: 80),
           "requested-window clipping must prorate against original duration")
    expect(result[1] == Span(start: 100, end: 110, kcal: 10),
           "a workout beginning at the previous workout's end must be included")
}

func testInputPermutationDoesNotChangeWinners() {
    let workouts = [
        Workout(start: 0, end: 80, kcal: 80, priority: 3, stableID: "b"),
        Workout(start: 20, end: 100, kcal: 160, priority: 3, stableID: "a"),
        Workout(start: 10, end: 90, kcal: 8, priority: 1, stableID: "low"),
    ]
    func resolve(_ input: [Workout]) -> [Span] {
        PulseActiveEnergyPolicy.supplementalSpans(local: input,
            externalCoverage: [Interval(start: 45, end: 50)], from: 0, to: 100,
            calendar: utcCalendar())
    }
    expect(resolve(workouts) == resolve(Array(workouts.reversed())),
           "input order must not affect overlap arbitration or output ordering")
}

func testCombinedTotalsReplaceBucketEnergyIdempotently() {
    let day = dayKey(2024, 1, 1)
    let start = timestamp(2024, 1, 1, calendar: utcCalendar())
    let inputSpan = Span(start: start, end: start + 60, kcal: 457.01194)
    let arguments: (baselineByDay: [String: Double], supplemental: [Span], baselineBuckets: [Bucket]) = (
        [day: 196.681], [inputSpan], [Bucket(start: start, end: start + 60, kcal: 4)])
    let first = PulseActiveEnergyPolicy.combinedTotals(
        baselineByDay: arguments.baselineByDay, supplemental: arguments.supplemental,
        baselineBuckets: arguments.baselineBuckets, calendar: utcCalendar())
    let repeated = PulseActiveEnergyPolicy.combinedTotals(
        baselineByDay: arguments.baselineByDay, supplemental: arguments.supplemental,
        baselineBuckets: arguments.baselineBuckets, calendar: utcCalendar())
    expect(close(first[day] ?? .nan, 649.69294),
           "combined total should keep 196.681 baseline, replace 4 overlapped kcal, and add 457.01194")
    expect(first == repeated, "repeating aggregation over the same baseline must be idempotent")
}

func testCombinedTotalsProratesAndClampsBaselineRemoval() {
    let day = dayKey(2024, 1, 1)
    let start = timestamp(2024, 1, 1, calendar: utcCalendar())
    let totals = PulseActiveEnergyPolicy.combinedTotals(
        baselineByDay: [day: 2],
        supplemental: [Span(start: start, end: start + 30, kcal: 10)],
        baselineBuckets: [Bucket(start: start, end: start + 60, kcal: 4)],
        calendar: utcCalendar())
    expect(close(totals[day] ?? .nan, 10),
           "half-minute overlap removes half the bucket energy and never makes the baseline negative")
}

func testCombinedTotalsIgnoresInvalidAndNonFiniteValues() {
    let invalidDay = dayKey(2024, 1, 1)
    let negativeDay = dayKey(2024, 1, 2)
    let validDay = dayKey(2024, 1, 3)
    let start = timestamp(2024, 1, 3, calendar: utcCalendar())
    let totals = PulseActiveEnergyPolicy.combinedTotals(
        baselineByDay: [invalidDay: .infinity, negativeDay: -10, validDay: 100],
        supplemental: [Span(start: .nan, end: start, kcal: 10),
                       Span(start: start, end: start + 60, kcal: .infinity),
                       Span(start: start, end: start + 60, kcal: 50)],
        baselineBuckets: [Bucket(start: start, end: start + 60, kcal: .nan),
                          Bucket(start: start + 60, end: start, kcal: 20),
                          Bucket(start: start, end: start + 60, kcal: -5),
                          Bucket(start: start, end: start + 60, kcal: .infinity),
                          Bucket(start: start, end: start + 60, kcal: 4)],
        calendar: utcCalendar())
    expect(totals[invalidDay] == 0 && totals[negativeDay] == 0,
           "nonfinite and negative daily baselines should become zero")
    expect(close(totals[validDay] ?? .nan, 146),
           "nonfinite supplemental and bucket values must be ignored safely")
    expect(totals.values.allSatisfy { $0.isFinite }, "combined results must remain finite")
}

testExternalWorkoutBlocksOnlyItsCoverage()
testPartialCoverageTrimsOnlyCoveredTimeAndEnergy()
testPriorityAndStableIDResolveLocalDuplicates()
testCrossMidnightSplitsAtLocalDayBoundary()
testSpringAndFallDayBoundariesFollowCalendarDST()
testClippingInvalidValuesAndTouchingWorkouts()
testInputPermutationDoesNotChangeWinners()
testCombinedTotalsReplaceBucketEnergyIdempotently()
testCombinedTotalsProratesAndClampsBaselineRemoval()
testCombinedTotalsIgnoresInvalidAndNonFiniteValues()
print("pulse active energy policy checks passed (10 scenarios)")
'''


@unittest.skipUnless(SWIFT, "swiftc is unavailable; Swift policy test skipped")
class PulseActiveEnergyPolicyTests(unittest.TestCase):
    def test_production_active_energy_policy(self) -> None:
        with tempfile.TemporaryDirectory(prefix="noop-pulse-active-energy-policy-") as temp_dir:
            temp = Path(temp_dir)
            module_cache = temp / "module-cache"
            module_cache.mkdir()
            harness = temp / "main.swift"
            executable = temp / "pulse-active-energy-policy-checks"
            harness.write_text(HARNESS, encoding="utf-8")
            compile_result = subprocess.run(
                [SWIFT, "-module-cache-path", str(module_cache), str(HELPER), str(harness),
                 "-o", str(executable)],
                cwd=ROOT, capture_output=True, text=True, check=False,
                env=os.environ.copy(), timeout=90,
            )
            self.assertEqual(compile_result.returncode, 0,
                             msg=f"swiftc failed:\n{compile_result.stdout}\n{compile_result.stderr}")
            run_result = subprocess.run([str(executable)], cwd=ROOT, capture_output=True,
                                        text=True, check=False, timeout=30)
            self.assertEqual(run_result.returncode, 0,
                             msg=f"policy checks failed:\n{run_result.stdout}\n{run_result.stderr}")
            self.assertIn("pulse active energy policy checks passed (10 scenarios)", run_result.stdout)


if __name__ == "__main__":
    unittest.main()
