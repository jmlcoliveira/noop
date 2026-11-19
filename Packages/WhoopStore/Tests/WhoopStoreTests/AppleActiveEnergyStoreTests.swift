import XCTest
import GRDB
@testable import WhoopStore

final class AppleActiveEnergyStoreTests: XCTestCase {

    private let source = "apple-health"
    private let otherSource = "other-health"

    private func daily(_ day: String, activeKcal: Double?) -> AppleDaily {
        AppleDaily(day: day, steps: 8_200, activeKcal: activeKcal, basalKcal: 1_256,
                   vo2max: 48.5, avgHr: 62, maxHr: 171, walkingHr: 98, weightKg: 78.4)
    }

    func testReplacementIsIdempotentAndPreservesOtherAppleDailyFields() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-11-15"
        try await store.upsertAppleDaily([daily(day, activeKcal: 196.7)], deviceId: source)
        try await store.upsertMetricSeries([
            MetricPoint(day: day, key: "active_kcal", value: 196.7),
            MetricPoint(day: day, key: "steps", value: 8_200),
        ], deviceId: source)

        let changed = try await store.replaceAppleActiveEnergy(
            [day: 653.7], deviceId: source, from: day, to: day)
        XCTAssertTrue(changed)

        var appleRows = try await store.appleDaily(deviceId: source, from: day, to: day)
        XCTAssertEqual(appleRows, [daily(day, activeKcal: 653.7)])
        var energyRows = try await store.metricSeries(deviceId: source, key: "active_kcal",
                                                      from: day, to: day)
        XCTAssertEqual(energyRows, [MetricPoint(day: day, key: "active_kcal", value: 653.7)])
        var stepsRows = try await store.metricSeries(deviceId: source, key: "steps", from: day, to: day)
        XCTAssertEqual(stepsRows, [MetricPoint(day: day, key: "steps", value: 8_200)])

        let unchanged = try await store.replaceAppleActiveEnergy(
            [day: 653.7], deviceId: source, from: day, to: day)
        XCTAssertFalse(unchanged, "an identical snapshot should not cause a store write")
        appleRows = try await store.appleDaily(deviceId: source, from: day, to: day)
        energyRows = try await store.metricSeries(deviceId: source, key: "active_kcal",
                                                  from: day, to: day)
        stepsRows = try await store.metricSeries(deviceId: source, key: "steps", from: day, to: day)
        XCTAssertEqual(appleRows, [daily(day, activeKcal: 653.7)])
        XCTAssertEqual(energyRows, [MetricPoint(day: day, key: "active_kcal", value: 653.7)])
        XCTAssertEqual(stepsRows, [MetricPoint(day: day, key: "steps", value: 8_200)])
    }

    func testReplacementClearsStaleValuesAndRetainsZero() async throws {
        let store = try await WhoopStore.inMemory()
        let first = "2026-11-14"
        let second = "2026-11-15"
        try await store.upsertAppleDaily([
            daily(first, activeKcal: 120), daily(second, activeKcal: 196.7),
        ], deviceId: source)
        try await store.upsertMetricSeries([
            MetricPoint(day: first, key: "active_kcal", value: 120),
            MetricPoint(day: second, key: "active_kcal", value: 196.7),
            MetricPoint(day: second, key: "steps", value: 8_200),
        ], deviceId: source)

        let zeroChanged = try await store.replaceAppleActiveEnergy(
            [second: 0], deviceId: source, from: first, to: second)
        XCTAssertTrue(zeroChanged)
        var appleRows = try await store.appleDaily(deviceId: source, from: first, to: second)
        XCTAssertEqual(appleRows, [daily(first, activeKcal: nil), daily(second, activeKcal: 0)])
        var energyRows = try await store.metricSeries(deviceId: source, key: "active_kcal",
                                                      from: first, to: second)
        XCTAssertEqual(energyRows, [MetricPoint(day: second, key: "active_kcal", value: 0)])

        let emptyChanged = try await store.replaceAppleActiveEnergy(
            [:], deviceId: source, from: first, to: second)
        XCTAssertTrue(emptyChanged)
        appleRows = try await store.appleDaily(deviceId: source, from: first, to: second)
        XCTAssertEqual(appleRows, [daily(first, activeKcal: nil), daily(second, activeKcal: nil)])
        energyRows = try await store.metricSeries(deviceId: source, key: "active_kcal",
                                                  from: first, to: second)
        XCTAssertTrue(energyRows.isEmpty)
        let stepsRows = try await store.metricSeries(deviceId: source, key: "steps",
                                                     from: first, to: second)
        XCTAssertEqual(stepsRows, [MetricPoint(day: second, key: "steps", value: 8_200)])

        let repeatedEmptyChanged = try await store.replaceAppleActiveEnergy(
            [:], deviceId: source, from: first, to: second)
        XCTAssertFalse(repeatedEmptyChanged)
    }

    func testReplacementIsLimitedToItsSourceAndInclusiveDayRange() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertAppleDaily([
            daily("2026-11-09", activeKcal: 90),
            daily("2026-11-12", activeKcal: 120),
            daily("2026-11-20", activeKcal: 200),
        ], deviceId: source)
        try await store.upsertAppleDaily([daily("2026-11-12", activeKcal: 88)], deviceId: otherSource)
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-11-09", key: "active_kcal", value: 90),
            MetricPoint(day: "2026-11-12", key: "active_kcal", value: 120),
            MetricPoint(day: "2026-11-20", key: "active_kcal", value: 200),
            MetricPoint(day: "2026-11-12", key: "steps", value: 8_200),
        ], deviceId: source)
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-11-12", key: "active_kcal", value: 88),
        ], deviceId: otherSource)

        let changed = try await store.replaceAppleActiveEnergy(
            ["2026-11-13": 500], deviceId: source, from: "2026-11-10", to: "2026-11-15")
        XCTAssertTrue(changed)

        let appleRows = try await store.appleDaily(deviceId: source, from: "2026-11-01", to: "2026-11-30")
        XCTAssertEqual(appleRows, [
            daily("2026-11-09", activeKcal: 90),
            daily("2026-11-12", activeKcal: nil),
            AppleDaily(day: "2026-11-13", steps: nil, activeKcal: 500, basalKcal: nil,
                       vo2max: nil, avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: nil),
            daily("2026-11-20", activeKcal: 200),
        ])
        let otherAppleRows = try await store.appleDaily(deviceId: otherSource,
                                                       from: "2026-11-01", to: "2026-11-30")
        XCTAssertEqual(otherAppleRows, [daily("2026-11-12", activeKcal: 88)])

        let energyRows = try await store.metricSeries(deviceId: source, key: "active_kcal",
                                                      from: "2026-11-01", to: "2026-11-30")
        XCTAssertEqual(energyRows, [
            MetricPoint(day: "2026-11-09", key: "active_kcal", value: 90),
            MetricPoint(day: "2026-11-13", key: "active_kcal", value: 500),
            MetricPoint(day: "2026-11-20", key: "active_kcal", value: 200),
        ])
        let stepsRows = try await store.metricSeries(deviceId: source, key: "steps",
                                                     from: "2026-11-01", to: "2026-11-30")
        XCTAssertEqual(stepsRows, [MetricPoint(day: "2026-11-12", key: "steps", value: 8_200)])
        let otherEnergyRows = try await store.metricSeries(deviceId: otherSource, key: "active_kcal",
                                                           from: "2026-11-01", to: "2026-11-30")
        XCTAssertEqual(otherEnergyRows,
                       [MetricPoint(day: "2026-11-12", key: "active_kcal", value: 88)])
    }

    func testInvalidInputDoesNotMutateEitherSurface() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-11-13"
        try await store.upsertAppleDaily([daily(day, activeKcal: 44)], deviceId: source)
        try await store.upsertMetricSeries([
            MetricPoint(day: day, key: "active_kcal", value: 44),
            MetricPoint(day: day, key: "steps", value: 8_200),
        ], deviceId: source)
        let originalApple = try await store.appleDaily(deviceId: source, from: day, to: day)
        let originalEnergy = try await store.metricSeries(deviceId: source, key: "active_kcal",
                                                           from: day, to: day)
        let originalSteps = try await store.metricSeries(deviceId: source, key: "steps",
                                                         from: day, to: day)

        let invalidCases: [([String: Double], String, String, AppleActiveEnergyStoreError)] = [
            ([:], "2026-11-15", "2026-11-10", .invalidDayRange),
            (["2026-11-16": 1], "2026-11-10", "2026-11-15", .dayOutsideRange("2026-11-16")),
            ([day: -1], "2026-11-10", "2026-11-15", .invalidKilocalories(day)),
            ([day: .nan], "2026-11-10", "2026-11-15", .invalidKilocalories(day)),
            ([day: .infinity], "2026-11-10", "2026-11-15", .invalidKilocalories(day)),
        ]

        for (values, from, to, expectedError) in invalidCases {
            do {
                _ = try await store.replaceAppleActiveEnergy(values, deviceId: source, from: from, to: to)
                XCTFail("expected validation failure: \(expectedError)")
            } catch let error as AppleActiveEnergyStoreError {
                XCTAssertEqual(error, expectedError)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
            let appleAfter = try await store.appleDaily(deviceId: source, from: day, to: day)
            let energyAfter = try await store.metricSeries(deviceId: source, key: "active_kcal",
                                                           from: day, to: day)
            let stepsAfter = try await store.metricSeries(deviceId: source, key: "steps",
                                                          from: day, to: day)
            XCTAssertEqual(appleAfter, originalApple)
            XCTAssertEqual(energyAfter, originalEnergy)
            XCTAssertEqual(stepsAfter, originalSteps)
        }
    }

    func testDatabaseFailureRollsBackBothReadSurfaces() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-11-15"
        try await store.upsertAppleDaily([daily(day, activeKcal: 44)], deviceId: source)
        try await store.upsertMetricSeries([
            MetricPoint(day: day, key: "active_kcal", value: 44)
        ], deviceId: source)
        try await store.syncWrite { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_energy_insert BEFORE INSERT ON metricSeries
                WHEN NEW.key = 'active_kcal'
                BEGIN SELECT RAISE(ABORT, 'injected energy write failure'); END
                """)
        }
        do {
            _ = try await store.replaceAppleActiveEnergy(
                [day: 653.7], deviceId: source, from: day, to: day)
            XCTFail("the injected database failure must propagate")
        } catch is DatabaseError {
            // The second table failed after the first was updated. The whole transaction must roll back.
        }
        let appleRows = try await store.appleDaily(deviceId: source, from: day, to: day)
        let series = try await store.metricSeries(deviceId: source, key: "active_kcal", from: day, to: day)
        XCTAssertEqual(appleRows, [daily(day, activeKcal: 44)])
        XCTAssertEqual(series, [MetricPoint(day: day, key: "active_kcal", value: 44)])
    }
}
