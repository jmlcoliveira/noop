import Foundation

/// Apple Health may already contain the original phone's exports. HealthKit's read
/// authorization is opaque, so an empty query cannot prove that replay is safe.
enum CloudBackupRestoreHealthPolicy {
    private static let defaultsKey = "cloudBackup.workoutExportFloor"

    static func floor(in defaults: UserDefaults = .standard) -> Int? {
        defaults.object(forKey: defaultsKey) as? Int
    }

    static func protectRestoredWorkouts(latestStart: Int?, at date: Date = Date(),
                                        in defaults: UserDefaults = .standard) {
        // Include workouts recorded on the previous phone while the restore was pending.
        let nextSecond = Int(date.timeIntervalSince1970.rounded(.down)) + 1
        let afterLatest = latestStart.map { $0 == Int.max ? $0 : $0 + 1 } ?? nextSecond
        defaults.set(max(floor(in: defaults) ?? 0, nextSecond, afterLatest), forKey: defaultsKey)
    }
}
