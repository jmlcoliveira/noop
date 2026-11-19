#if os(iOS)
import Foundation
import HealthKit
import WhoopStore

/// Derives Pulse's displayed total without changing HealthKit or its separately stored raw series.
/// Whole-day HR estimates include resting energy and must never be added here.
@MainActor
enum PulseActiveEnergyCollector {
    enum ReadError: Error { case incompleteWorkouts, invalidQuantity }

    static func snapshot(store: HKHealthStore, local: [WorkoutRow], start: Date, end: Date,
                         calendar: Calendar = .current) async throws -> [String: Double] {
        async let dailyRead = energyBuckets(store: store, start: start, end: end,
            interval: DateComponents(day: 1), anchor: calendar.startOfDay(for: start))
        async let workoutsRead = workouts(store: store, start: start, end: end)
        let (daily, healthWorkouts) = try await (dailyRead, workoutsRead)
        var baseline: [String: Double] = [:]
        for bucket in daily {
            baseline[day(bucket.start, calendar: calendar), default: 0] += bucket.kcal
        }
        let candidates = local.compactMap { row -> PulseActiveEnergyPolicy.Workout? in
            guard let kcal = row.energyKcal else { return nil }
            let priority: Int
            switch WorkoutSource.classify(row.source) {
            case .manual: priority = 300
            case .detected: priority = 100
            // Imported sessions belong to the Health baseline, rather than being new Pulse activity.
            case .apple, .whoop, .lifting, .activityFile: return nil
            }
            return .init(start: Double(row.startTs), end: Double(row.endTs), kcal: kcal,
                         priority: priority,
                         stableID: "\(row.source)|\(row.startTs)|\(row.endTs)|\(row.sport)|\(kcal)")
        }
        var externalCoverage: [PulseActiveEnergyPolicy.Interval] = []
        for workout in healthWorkouts {
            let lo = workout.startDate.timeIntervalSince1970
            let hi = workout.endDate.timeIntervalSince1970
            if workout.sourceRevision.source != HKSource.default(), lo.isFinite, hi.isFinite, hi > lo {
                // Hevy/Watch/WHOOP sessions mask local detections, even without an energy summary.
                // Own exported copies never create a workout absent from the current local store.
                externalCoverage.append(.init(start: lo, end: hi))
            }
        }
        let coverage = externalCoverage
        let lo = start.timeIntervalSince1970, hi = end.timeIntervalSince1970
        let spans = await Task.detached(priority: .utility) {
            PulseActiveEnergyPolicy.supplementalSpans(local: candidates,
                externalCoverage: coverage, from: lo, to: hi, calendar: calendar)
        }.value
        guard let first = spans.first, let last = spans.last else { return baseline }

        // One bounded minute query replaces phone movement during the Pulse-only intervals.
        // Boundary minutes are allocated proportionally; their sub-minute timing is an estimate.
        let minuteStart = calendar.dateInterval(of: .minute,
            for: Date(timeIntervalSince1970: first.start))!.start
        let minuteEnd = min(end, calendar.dateInterval(of: .minute,
            for: Date(timeIntervalSince1970: last.end))!.end)
        let buckets = try await energyBuckets(store: store, start: minuteStart, end: minuteEnd,
            interval: DateComponents(minute: 1), anchor: minuteStart)
        let dailyBaseline = baseline
        return await Task.detached(priority: .utility) {
            PulseActiveEnergyPolicy.combinedTotals(baselineByDay: dailyBaseline,
                supplemental: spans, baselineBuckets: buckets, calendar: calendar)
        }.value
    }

    private static func day(_ timestamp: Double, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: timestamp))
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private static func energyBuckets(store: HKHealthStore, start: Date, end: Date,
                                      interval: DateComponents, anchor: Date) async throws -> [PulseActiveEnergyPolicy.Bucket] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end, options: []),
            NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: [HKSource.default()])),
        ])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(quantityType: HKQuantityType(.activeEnergyBurned),
                quantitySamplePredicate: predicate, options: .cumulativeSum,
                anchorDate: anchor, intervalComponents: interval)
            query.initialResultsHandler = { _, result, error in
                if let error { continuation.resume(throwing: error); return }
                guard let result else { continuation.resume(throwing: ReadError.invalidQuantity); return }
                var buckets: [PulseActiveEnergyPolicy.Bucket] = []
                var invalid = false
                result.enumerateStatistics(from: start, to: end) { statistics, _ in
                    guard let quantity = statistics.sumQuantity() else { return }
                    let kcal = quantity.doubleValue(for: .kilocalorie())
                    guard kcal.isFinite, kcal >= 0 else { invalid = true; return }
                    buckets.append(.init(start: statistics.startDate.timeIntervalSince1970,
                        end: statistics.endDate.timeIntervalSince1970, kcal: kcal))
                }
                if invalid { continuation.resume(throwing: ReadError.invalidQuantity) }
                else { continuation.resume(returning: buckets) }
            }
            store.execute(query)
        }
    }

    private static func workouts(store: HKHealthStore, start: Date, end: Date) async throws -> [HKWorkout] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForSamples(withStart: start, end: end, options: []),
                NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: [HKSource.default()])),
            ])
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 10_001, sortDescriptors: nil) { _, samples, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let samples, samples.count < 10_001 else {
                        continuation.resume(throwing: ReadError.incompleteWorkouts); return
                    }
                    continuation.resume(returning: samples.compactMap { $0 as? HKWorkout })
                }
            store.execute(query)
        }
    }
}
#endif
