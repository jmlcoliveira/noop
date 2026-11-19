import Foundation

/// Values Pulse exports for one HealthKit workout. Bad quantity values are omitted from the sample.
struct WorkoutExportPayload: Codable, Equatable {
    let startTs: Int
    let endTs: Int
    let activityType: String
    let activeEnergyKcal: Double?
    let distanceType: String?
    let distanceM: Double?

    init?(startTs: Int, endTs: Int, activityType: String,
          activeEnergyKcal: Double?, distanceType: String?, distanceM: Double?) {
        guard endTs > startTs, !activityType.isEmpty else { return nil }
        self.startTs = startTs
        self.endTs = endTs
        self.activityType = activityType
        self.activeEnergyKcal = Self.valid(activeEnergyKcal)
        let validDistance = distanceType == nil ? nil : Self.valid(distanceM)
        self.distanceM = validDistance
        self.distanceType = validDistance == nil ? nil : distanceType
    }

    func matches(_ other: WorkoutExportPayload) -> Bool {
        startTs == other.startTs && endTs == other.endTs && activityType == other.activityType
            && distanceType == other.distanceType
            && Self.same(activeEnergyKcal, other.activeEnergyKcal, tolerance: 0.01)
            && Self.same(distanceM, other.distanceM, tolerance: 0.1)
    }

    private static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func same(_ lhs: Double?, _ rhs: Double?, tolerance: Double) -> Bool {
        return switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): abs(lhs - rhs) <= tolerance
        default: false
        }
    }
}

/// Persisted before a HealthKit save, so an interrupted retry reuses its version.
struct WorkoutExportLedgerEntry: Codable, Equatable {
    let payload: WorkoutExportPayload
    let syncVersion: Int
    let isComplete: Bool
    let pendingRetireTypeIds: [String]
}

struct WorkoutExportCandidate: Equatable {
    let key: String
    let sourcePriority: Int
    let stableTieBreak: String
}

enum WorkoutExportLedgerAction: Equatable {
    case skip
    case adopt(version: Int)
    case save(version: Int)
}

enum WorkoutExportLedgerPolicy {
    static func action(payload: WorkoutExportPayload, previous: WorkoutExportLedgerEntry?,
                       hasMatchingExisting: Bool, matchingExistingVersion: Int?,
                       highestObservedVersion: Int?,
                       nowVersion: Int) -> WorkoutExportLedgerAction {
        if hasMatchingExisting {
            return .adopt(version: max(0, max(matchingExistingVersion ?? 0, previous?.syncVersion ?? 0)))
        }
        if let previous, previous.payload == payload,
           (highestObservedVersion ?? 0) <= previous.syncVersion {
            return previous.isComplete ? .skip : .save(version: previous.syncVersion)
        }
        let highest = max(previous?.syncVersion ?? 0, highestObservedVersion ?? 0)
        let next = max(1, max(nowVersion, highest == Int.max ? Int.max : highest + 1))
        return .save(version: next)
    }

    static func canonicalIndices(_ candidates: [WorkoutExportCandidate]) -> [Int] {
        var winners: [String: Int] = [:]
        for (index, candidate) in candidates.enumerated() {
            guard let oldIndex = winners[candidate.key] else {
                winners[candidate.key] = index
                continue
            }
            let old = candidates[oldIndex]
            if candidate.sourcePriority > old.sourcePriority
                || (candidate.sourcePriority == old.sourcePriority
                    && candidate.stableTieBreak < old.stableTieBreak) {
                winners[candidate.key] = index
            }
        }
        return winners.values.sorted()
    }

    static func pendingRetireTypes(_ typeIds: [String], preserving payload: WorkoutExportPayload) -> [String] {
        let activeEnergy = "HKQuantityTypeIdentifierActiveEnergyBurned"
        return Array(Set(typeIds.filter { typeId in
            if payload.activeEnergyKcal != nil && typeId == activeEnergy { return false }
            if payload.distanceM != nil && payload.distanceType == typeId { return false }
            return true
        })).sorted()
    }

    static func intent(payload: WorkoutExportPayload, version: Int,
                       pendingRetireTypeIds: [String] = []) -> WorkoutExportLedgerEntry {
        WorkoutExportLedgerEntry(payload: payload, syncVersion: version, isComplete: false,
                                 pendingRetireTypeIds: pendingRetireTypeIds)
    }

    static func completed(payload: WorkoutExportPayload, version: Int) -> WorkoutExportLedgerEntry {
        WorkoutExportLedgerEntry(payload: payload, syncVersion: version, isComplete: true,
                                 pendingRetireTypeIds: [])
    }
}
