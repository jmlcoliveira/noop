import Foundation
import GRDB

public enum MetricSeriesSnapshotError: Error, Equatable, Sendable {
    case invalidRange
    case invalidPoint(String)
}

extension WhoopStore {
    /// Atomically replace one derived series within a day range. Other sources, keys and days survive.
    /// Identical snapshots avoid a write and therefore do not trigger another dashboard refresh.
    @discardableResult
    public func replaceMetricSeriesSnapshot(_ values: [String: Double], deviceId: String, key: String,
                                            from: String, to: String) async throws -> Bool {
        guard from <= to else { throw MetricSeriesSnapshotError.invalidRange }
        for (day, value) in values {
            guard day >= from, day <= to, value.isFinite, value >= 0 else {
                throw MetricSeriesSnapshotError.invalidPoint(day)
            }
        }
        return try syncWrite { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT day, value FROM metricSeries
                WHERE deviceId = ? AND key = ? AND day >= ? AND day <= ?
                """, arguments: [deviceId, key, from, to])
            var existing: [String: Double] = [:]
            for row in rows { existing[row["day"] as String] = row["value"] as Double }
            guard existing != values else { return false }
            try db.execute(sql: """
                DELETE FROM metricSeries
                WHERE deviceId = ? AND key = ? AND day >= ? AND day <= ?
                """, arguments: [deviceId, key, from, to])
            _ = try Self.upsertMetricSeries(values.map {
                MetricPoint(day: $0.key, key: key, value: $0.value)
            }, deviceId: deviceId, in: db)
            return true
        }
    }
}
