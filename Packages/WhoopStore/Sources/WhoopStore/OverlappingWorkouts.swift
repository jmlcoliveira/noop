import GRDB

extension WhoopStore {
    /// Half-open interval read, including sessions beginning before the requested window.
    public func workoutsOverlapping(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [WorkoutRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT startTs, endTs, sport, source, durationS, energyKcal, avgHr, maxHr,
                       strain, distanceM, zonesJSON, notes, steps FROM workout
                WHERE deviceId = ? AND endTs > ? AND startTs < ?
                ORDER BY startTs ASC, sport ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit]).map {
                    WorkoutRow(startTs: $0["startTs"], endTs: $0["endTs"], sport: $0["sport"],
                        source: $0["source"], durationS: $0["durationS"], energyKcal: $0["energyKcal"],
                        avgHr: $0["avgHr"], maxHr: $0["maxHr"], strain: $0["strain"],
                        distanceM: $0["distanceM"], zonesJSON: $0["zonesJSON"], notes: $0["notes"], steps: $0["steps"])
                }
        }
    }
}
