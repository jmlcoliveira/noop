import XCTest
@testable import WhoopStore

final class MetricSeriesSnapshotTests: XCTestCase {
    func testWorkoutReadIncludesCrossMidnightAndExcludesTouchingSessions() async throws {
        let store = try await WhoopStore.inMemory()
        func workout(_ start: Int, _ end: Int) -> WorkoutRow {
            WorkoutRow(startTs: start, endTs: end, sport: "Stair Stepper", source: "manual",
                durationS: Double(end - start), energyKcal: 100, avgHr: nil, maxHr: nil,
                strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        }
        try await store.upsertWorkouts([workout(10, 20), workout(15, 25), workout(20, 30),
                                      workout(30, 40)], deviceId: "my-whoop")
        try await store.upsertWorkouts([workout(20, 29)], deviceId: "apple-health")
        let rows = try await store.workoutsOverlapping(deviceId: "my-whoop", from: 20, to: 30, limit: 100)
        XCTAssertEqual(rows.map(\.startTs), [15, 20])
    }

    func testReplacementIsScopedAndIdempotent() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-11-15"
        try await store.upsertMetricSeries([
            MetricPoint(day: day, key: "active_kcal", value: 197),
        ], deviceId: "apple-health")
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-11-01", key: "active_kcal", value: 80),
            MetricPoint(day: "2026-11-14", key: "active_kcal", value: 90),
            MetricPoint(day: day, key: "steps", value: 2551),
        ], deviceId: "pulse-energy")
        let changed = try await store.replaceMetricSeriesSnapshot([day: 649.7],
            deviceId: "pulse-energy", key: "active_kcal", from: "2026-11-14", to: day)
        XCTAssertTrue(changed)
        let unchanged = try await store.replaceMetricSeriesSnapshot([day: 649.7],
            deviceId: "pulse-energy", key: "active_kcal", from: "2026-11-14", to: day)
        XCTAssertFalse(unchanged)
        let derived = try await store.metricSeries(deviceId: "pulse-energy", key: "active_kcal",
                                                   from: "2026-11-01", to: day)
        XCTAssertEqual(derived, [MetricPoint(day: "2026-11-01", key: "active_kcal", value: 80),
                                 MetricPoint(day: day, key: "active_kcal", value: 649.7)])
        let raw = try await store.metricSeries(deviceId: "apple-health", key: "active_kcal", from: day, to: day)
        XCTAssertEqual(raw.first?.value, 197)
        let steps = try await store.metricSeries(deviceId: "pulse-energy", key: "steps", from: day, to: day)
        XCTAssertEqual(steps.first?.value, 2551)
    }

    func testZeroAndEmptyAreAuthoritativeAndInvalidSnapshotsDoNotMutate() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-11-15"
        try await store.replaceMetricSeriesSnapshot([day: 0], deviceId: "pulse-energy",
            key: "active_kcal", from: day, to: day)
        for invalid in [[day: Double.nan], [day: -1], ["2026-11-16": 100]] {
            do {
                try await store.replaceMetricSeriesSnapshot(invalid, deviceId: "pulse-energy",
                    key: "active_kcal", from: day, to: day)
                XCTFail("invalid snapshot must fail before mutation")
            } catch is MetricSeriesSnapshotError { }
        }
        let zero = try await store.metricSeries(deviceId: "pulse-energy", key: "active_kcal", from: day, to: day)
        XCTAssertEqual(zero.first?.value, 0)
        try await store.replaceMetricSeriesSnapshot([:], deviceId: "pulse-energy",
            key: "active_kcal", from: day, to: day)
        let empty = try await store.metricSeries(deviceId: "pulse-energy", key: "active_kcal", from: day, to: day)
        XCTAssertTrue(empty.isEmpty)
    }
}
