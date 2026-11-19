import Foundation
import GRDB

/// Validation failures for an Apple Health active-energy replacement.
public enum AppleActiveEnergyStoreError: Error, Equatable, Sendable {
    case invalidDayRange
    case dayOutsideRange(String)
    case invalidKilocalories(String)
}

extension WhoopStore {

    /// Replace Apple active-energy totals in an inclusive day range, atomically and for one source.
    /// Existing AppleDaily rows keep every other field; metricSeries `active_kcal` points are replaced
    /// over the same range. An empty dictionary clears active energy in the range without deleting its
    /// AppleDaily rows. A zero total remains an explicit reading. Returns false when both surfaces
    /// already match the supplied snapshot, avoiding a write for duplicate sync notifications.
    @discardableResult
    public func replaceAppleActiveEnergy(_ kcalByDay: [String: Double], deviceId: String,
                                         from: String, to: String) async throws -> Bool {
        guard from <= to else { throw AppleActiveEnergyStoreError.invalidDayRange }
        for (day, kcal) in kcalByDay {
            guard day >= from, day <= to else {
                throw AppleActiveEnergyStoreError.dayOutsideRange(day)
            }
            guard kcal.isFinite, kcal >= 0 else {
                throw AppleActiveEnergyStoreError.invalidKilocalories(day)
            }
        }

        return try syncWrite { db in
            let appleRows = try Row.fetchAll(db, sql: """
                SELECT day, activeKcal FROM appleDaily
                WHERE deviceId = ? AND day >= ? AND day <= ? AND activeKcal IS NOT NULL
                """, arguments: [deviceId, from, to])
            var appleValues: [String: Double] = [:]
            for row in appleRows {
                let day: String = row["day"]
                let kcal: Double = row["activeKcal"]
                appleValues[day] = kcal
            }

            let seriesRows = try Row.fetchAll(db, sql: """
                SELECT day, value FROM metricSeries
                WHERE deviceId = ? AND key = 'active_kcal' AND day >= ? AND day <= ?
                """, arguments: [deviceId, from, to])
            var seriesValues: [String: Double] = [:]
            for row in seriesRows {
                let day: String = row["day"]
                let kcal: Double = row["value"]
                seriesValues[day] = kcal
            }

            // Do not churn either table when both read surfaces already hold this exact snapshot.
            guard appleValues != kcalByDay || seriesValues != kcalByDay else { return false }

            try db.execute(sql: """
                UPDATE appleDaily
                SET activeKcal = NULL
                WHERE deviceId = ? AND day >= ? AND day <= ?
                """, arguments: [deviceId, from, to])

            try db.execute(sql: """
                DELETE FROM metricSeries
                WHERE deviceId = ? AND key = 'active_kcal' AND day >= ? AND day <= ?
                """, arguments: [deviceId, from, to])

            for (day, kcal) in kcalByDay.sorted(by: { $0.key < $1.key }) {
                // Insert a sparse AppleDaily row when the day has no other Health metrics. On conflict,
                // update only activeKcal so an energy refresh cannot erase steps, HR, or other fields.
                try db.execute(sql: """
                    INSERT INTO appleDaily (deviceId, day, activeKcal)
                    VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, day) DO UPDATE SET activeKcal = excluded.activeKcal
                    """, arguments: [deviceId, day, kcal])

                try db.execute(sql: """
                    INSERT INTO metricSeries (deviceId, day, key, value)
                    VALUES (?, ?, 'active_kcal', ?)
                    ON CONFLICT(deviceId, day, key) DO UPDATE SET value = excluded.value
                    """, arguments: [deviceId, day, kcal])
            }
            return true
        }
    }
}
