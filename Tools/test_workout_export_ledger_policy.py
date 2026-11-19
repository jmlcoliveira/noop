"""Compile and exercise the production Foundation-only HealthKit export policy."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "StrandiOS" / "Health" / "WorkoutExportLedgerPolicy.swift"
SWIFT = shutil.which("swiftc")


HARNESS = r'''import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

func payload(_ kcal: Double? = 457, sport: String = "running") -> WorkoutExportPayload {
    WorkoutExportPayload(startTs: 1_794_745_546, endTs: 1_794_747_203,
                         activityType: sport, activeEnergyKcal: kcal,
                         distanceType: "HKQuantityTypeIdentifierDistanceWalkingRunning",
                         distanceM: 1_200)!
}

func testRepeatedExportsStayAtOneVersion() {
    let current = payload()
    var ledger = WorkoutExportLedgerPolicy.completed(payload: current, version: 1_794_745_600)
    for tick in 0..<1_000 {
        let action = WorkoutExportLedgerPolicy.action(
            payload: current, previous: ledger, hasMatchingExisting: false,
            matchingExistingVersion: nil,
            highestObservedVersion: nil, nowVersion: 1_794_745_600 + tick)
        expect(action == .skip, "unchanged committed exports must never be re-saved")
    }
    ledger = WorkoutExportLedgerPolicy.completed(payload: current, version: ledger.syncVersion)
    expect(ledger.syncVersion == 1_794_745_600, "identical retries must not increase sync version")
}

func testChangedPayloadGetsVersionAboveLocalAndHealthKitState() {
    let old = WorkoutExportLedgerPolicy.completed(payload: payload(), version: 100)
    let changed = WorkoutExportLedgerPolicy.action(
        payload: payload(458), previous: old, hasMatchingExisting: false,
        matchingExistingVersion: nil,
        highestObservedVersion: 200, nowVersion: 150)
    expect(changed == .save(version: 201), "edits must advance beyond the observed HealthKit version")
}

func testNewerObservedExportCannotBeSkippedByOlderLocalState() {
    let current = payload()
    let old = WorkoutExportLedgerPolicy.completed(payload: current, version: 100)
    let action = WorkoutExportLedgerPolicy.action(
        payload: current, previous: old, hasMatchingExisting: false,
        matchingExistingVersion: nil, highestObservedVersion: 200, nowVersion: 150)
    expect(action == .save(version: 201), "newer divergent Health state needs a higher replacement version")
}

func testInterruptedSaveReusesItsPersistedIntentVersion() {
    let current = payload()
    let pending = WorkoutExportLedgerPolicy.intent(payload: current, version: 300)
    let retry = WorkoutExportLedgerPolicy.action(
        payload: current, previous: pending, hasMatchingExisting: false,
        matchingExistingVersion: nil,
        highestObservedVersion: nil, nowVersion: 500)
    expect(retry == .save(version: 300), "retry must reuse the intent version after a crash")
}

func testMatchingLegacyWorkoutIsAdoptedWithoutRewrite() {
    let expected = payload()
    let actual = payload(457.005)
    expect(expected.matches(actual), "round-trip kcal precision should match a legacy workout")
    let action = WorkoutExportLedgerPolicy.action(
        payload: expected, previous: nil, hasMatchingExisting: true,
        matchingExistingVersion: nil, highestObservedVersion: nil, nowVersion: 400)
    expect(action == .adopt(version: 0), "matching legacy data must be adopted without a rewrite")
}

func testLegacyWorkoutWithoutDistanceMatchesNormalizedPayload() {
    let expected = WorkoutExportPayload(
        startTs: 10, endTs: 20, activityType: "running", activeEnergyKcal: nil,
        distanceType: "HKQuantityTypeIdentifierDistanceWalkingRunning", distanceM: nil)!
    let legacy = WorkoutExportPayload(
        startTs: 10, endTs: 20, activityType: "running", activeEnergyKcal: nil,
        distanceType: nil, distanceM: nil)!
    expect(expected.distanceType == nil && expected.distanceM == nil,
           "a type without an emitted distance must normalize away")
    expect(expected.matches(legacy), "legacy no-distance workout should match")
    let action = WorkoutExportLedgerPolicy.action(
        payload: expected, previous: nil, hasMatchingExisting: true,
        matchingExistingVersion: nil, highestObservedVersion: nil, nowVersion: 400)
    expect(action == .adopt(version: 0), "no-distance legacy row should be adopted")
}

func testNonFiniteEnergyIsOmittedFromSignature() {
    let bad = payload(.nan)
    let ordinary = payload(nil)
    expect(bad.activeEnergyKcal == nil, "NaN must never become a HealthKit quantity")
    expect(bad == ordinary, "invalid energy must not make every retry look changed")
}

func testPendingRetirementKeepsAReintroducedQuantity() {
    let restored = payload(457)
    let pending = [
        "HKQuantityTypeIdentifierActiveEnergyBurned",
        "HKQuantityTypeIdentifierDistanceWalkingRunning",
        "HKQuantityTypeIdentifierDistanceCycling",
    ]
    let remaining = WorkoutExportLedgerPolicy.pendingRetireTypes(pending, preserving: restored)
    expect(remaining == ["HKQuantityTypeIdentifierDistanceCycling"],
           "a failed old cleanup must not delete an energy/distance sample that is emitted again")
}

func testCanonicalizationUsesActualHealthKitKey() {
    let candidates = [
        WorkoutExportCandidate(key: "noop:workout:10", sourcePriority: 0, stableTieBreak: "running"),
        WorkoutExportCandidate(key: "noop:workout:10", sourcePriority: 1, stableTieBreak: "cycling"),
        WorkoutExportCandidate(key: "noop:workout:20", sourcePriority: 1, stableTieBreak: "walking"),
        WorkoutExportCandidate(key: "noop:workout:10", sourcePriority: 1, stableTieBreak: "boxing"),
    ]
    let winners = WorkoutExportLedgerPolicy.canonicalIndices(candidates)
    expect(winners == [2, 3], "one deterministic raw-row winner must exist per external UUID")
}

func testLedgerRoundTripsForCrashRecovery() throws {
    let entry = WorkoutExportLedgerPolicy.intent(payload: payload(), version: 123)
    let data = try JSONEncoder().encode(entry)
    let restored = try JSONDecoder().decode(WorkoutExportLedgerEntry.self, from: data)
    expect(restored == entry, "pending version intent must survive persistence")
}

testRepeatedExportsStayAtOneVersion()
testChangedPayloadGetsVersionAboveLocalAndHealthKitState()
testNewerObservedExportCannotBeSkippedByOlderLocalState()
testInterruptedSaveReusesItsPersistedIntentVersion()
testMatchingLegacyWorkoutIsAdoptedWithoutRewrite()
testLegacyWorkoutWithoutDistanceMatchesNormalizedPayload()
testNonFiniteEnergyIsOmittedFromSignature()
testPendingRetirementKeepsAReintroducedQuantity()
testCanonicalizationUsesActualHealthKitKey()
try testLedgerRoundTripsForCrashRecovery()
print("workout export ledger checks passed (10 scenarios)")
'''


@unittest.skipUnless(SWIFT, "swiftc is unavailable; Swift policy test skipped")
class WorkoutExportLedgerPolicyTests(unittest.TestCase):
    def test_production_export_policy(self) -> None:
        with tempfile.TemporaryDirectory(prefix="noop-workout-export-policy-") as temp_dir:
            temp = Path(temp_dir)
            module_cache = temp / "module-cache"
            module_cache.mkdir()
            harness = temp / "main.swift"
            executable = temp / "workout-export-policy-checks"
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
            self.assertIn("workout export ledger checks passed (10 scenarios)", run_result.stdout)


if __name__ == "__main__":
    unittest.main()
