import Foundation

/// iOS HealthKit source reconciliation, independent of HealthKit objects for standalone testing.
/// This does not change the shared physiological energy-estimation formula.
public enum PulseActiveEnergyPolicy {
    public struct Workout: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let kcal: Double
        public let priority: Int
        public let stableID: String

        public init(start: Double, end: Double, kcal: Double, priority: Int, stableID: String) {
            self.start = start
            self.end = end
            self.kcal = kcal
            self.priority = priority
            self.stableID = stableID
        }
    }

    public struct Interval: Equatable, Sendable {
        public let start: Double
        public let end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    public struct Span: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let kcal: Double

        public init(start: Double, end: Double, kcal: Double) {
            self.start = start
            self.end = end
            self.kcal = kcal
        }
    }

    public struct Bucket: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let kcal: Double

        public init(start: Double, end: Double, kcal: Double) {
            self.start = start
            self.end = end
            self.kcal = kcal
        }
    }

    private struct ClippedWorkout {
        let workout: Workout
        let clippedStart: Double
        let clippedEnd: Double
        let originalDuration: Double
    }

    private struct OutputSpan {
        let span: Span
        let workout: Workout
        let dayStart: Double
    }

    /// Returns the winning local workout energy outside externally covered intervals.
    ///
    /// Workouts are clipped to `from ..< to`; their energy is prorated against the
    /// original workout duration. Higher priority wins an overlap, with the
    /// lexicographically smaller stable ID breaking equal-priority ties. Results are
    /// split at local calendar midnights so callers can assign each span to one day.
    public static func supplementalSpans(
        local: [Workout],
        externalCoverage: [Interval],
        from: Double,
        to: Double,
        calendar: Calendar
    ) -> [Span] {
        guard from.isFinite, to.isFinite, to > from else { return [] }

        let workouts = local.compactMap { workout -> ClippedWorkout? in
            let duration = workout.end - workout.start
            guard workout.start.isFinite, workout.end.isFinite,
                  workout.kcal.isFinite, workout.kcal > 0,
                  duration.isFinite, duration > 0 else { return nil }
            let start = max(from, workout.start)
            let end = min(to, workout.end)
            guard end > start else { return nil }
            return ClippedWorkout(workout: workout, clippedStart: start,
                                  clippedEnd: end, originalDuration: duration)
        }
        guard !workouts.isEmpty else { return [] }

        let coverage = mergedCoverage(externalCoverage, from: from, to: to)
        var boundaries = [from, to]
        boundaries.reserveCapacity(2 + workouts.count * 2 + coverage.count * 2)
        for workout in workouts {
            boundaries.append(workout.clippedStart)
            boundaries.append(workout.clippedEnd)
        }
        for interval in coverage {
            boundaries.append(interval.start)
            boundaries.append(interval.end)
        }
        boundaries.sort()
        var uniqueBoundaries: [Double] = []
        uniqueBoundaries.reserveCapacity(boundaries.count)
        for boundary in boundaries where uniqueBoundaries.last != boundary {
            uniqueBoundaries.append(boundary)
        }

        var output: [OutputSpan] = []
        var coverageIndex = 0
        for index in 0..<(uniqueBoundaries.count - 1) {
            let start = uniqueBoundaries[index]
            let end = uniqueBoundaries[index + 1]
            guard end > start else { continue }

            while coverageIndex < coverage.count, coverage[coverageIndex].end <= start {
                coverageIndex += 1
            }
            if coverageIndex < coverage.count,
               coverage[coverageIndex].start <= start,
               coverage[coverageIndex].end >= end {
                continue
            }

            var winner: ClippedWorkout?
            for candidate in workouts
            where candidate.clippedStart <= start && candidate.clippedEnd >= end {
                if let current = winner {
                    if isPreferred(candidate.workout, to: current.workout) {
                        winner = candidate
                    }
                } else {
                    winner = candidate
                }
            }
            guard let winner else { continue }

            appendByLocalDay(start: start, end: end, kcal: winner.workout.kcal,
                             originalDuration: winner.originalDuration,
                             workout: winner.workout, calendar: calendar, into: &output)
        }
        return output.map(\.span)
    }

    /// Replaces minute-bucket energy inside local workout spans with local workout energy.
    ///
    /// Baseline values and buckets must exclude data owned by this app. Buckets are
    /// prorated by the fraction of each bucket covered by a span.
    /// Minute-boundary allocation is an approximation because the stored Health samples
    /// do not expose their within-minute energy distribution.
    public static func combinedTotals(
        baselineByDay: [String: Double],
        supplemental: [Span],
        baselineBuckets: [Bucket],
        calendar: Calendar
    ) -> [String: Double] {
        var baseline: [String: Double] = [:]
        for (day, kcal) in baselineByDay {
            baseline[day] = kcal.isFinite ? max(0, kcal) : 0
        }

        var addedByDay: [String: Double] = [:]
        for span in supplemental where valid(span.start, span.end, span.kcal) {
            split(start: span.start, end: span.end, kcal: span.kcal, calendar: calendar) { day, kcal in
                addedByDay[day] = saturatingAdd(addedByDay[day] ?? 0, kcal)
            }
        }

        var removedByDay: [String: Double] = [:]
        let buckets = baselineBuckets.filter { valid($0.start, $0.end, $0.kcal) }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        let spans = supplemental.filter { valid($0.start, $0.end, $0.kcal) }
        let coverage: [Interval]
        if let earliest = spans.map(\.start).min(), let latest = spans.map(\.end).max() {
            // The policy emits disjoint spans. Merge once defensively so accidental
            // overlaps cannot subtract the same baseline energy twice.
            coverage = mergedCoverage(spans.map { Interval(start: $0.start, end: $0.end) },
                                      from: earliest, to: latest)
        } else {
            coverage = []
        }
        var coverageIndex = 0
        for bucket in buckets {
            let duration = bucket.end - bucket.start
            guard duration.isFinite, duration > 0 else { continue }
            while coverageIndex < coverage.count, coverage[coverageIndex].end <= bucket.start {
                coverageIndex += 1
            }
            var coveredIndex = coverageIndex
            while coveredIndex < coverage.count, coverage[coveredIndex].start < bucket.end {
                let interval = coverage[coveredIndex]
                let start = max(bucket.start, interval.start)
                let end = min(bucket.end, interval.end)
                if end > start {
                    let energy = bucket.kcal * ((end - start) / duration)
                    split(start: start, end: end, kcal: energy, calendar: calendar) { day, kcal in
                        removedByDay[day] = saturatingAdd(removedByDay[day] ?? 0, kcal)
                    }
                }
                coveredIndex += 1
            }
        }

        var days = Set(baseline.keys)
        days.formUnion(addedByDay.keys)
        days.formUnion(removedByDay.keys)
        var totals: [String: Double] = [:]
        for day in days {
            let remainingBaseline = max(0, (baseline[day] ?? 0) - (removedByDay[day] ?? 0))
            totals[day] = saturatingAdd(remainingBaseline, addedByDay[day] ?? 0)
        }
        return totals
    }

    private static func valid(_ start: Double, _ end: Double, _ kcal: Double) -> Bool {
        let duration = end - start
        return start.isFinite && end.isFinite && kcal.isFinite && kcal > 0
            && duration.isFinite && duration > 0
    }

    private static func saturatingAdd(_ lhs: Double, _ rhs: Double) -> Double {
        let sum = lhs + rhs
        guard !sum.isFinite else { return sum }
        return sum.sign == .minus ? -Double.greatestFiniteMagnitude : Double.greatestFiniteMagnitude
    }

    private static func isPreferred(_ candidate: Workout, to current: Workout) -> Bool {
        if candidate.priority != current.priority {
            return candidate.priority > current.priority
        }
        if candidate.stableID != current.stableID {
            return candidate.stableID < current.stableID
        }
        if candidate.start != current.start { return candidate.start < current.start }
        if candidate.end != current.end { return candidate.end < current.end }
        return candidate.kcal < current.kcal
    }

    private static func mergedCoverage(_ intervals: [Interval], from: Double, to: Double) -> [Interval] {
        let clipped = intervals.compactMap { interval -> Interval? in
            guard interval.start.isFinite, interval.end.isFinite, interval.end > interval.start else {
                return nil
            }
            let start = max(from, interval.start)
            let end = min(to, interval.end)
            return end > start ? Interval(start: start, end: end) : nil
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }

        var merged: [Interval] = []
        for interval in clipped {
            if let previous = merged.last, interval.start <= previous.end {
                merged[merged.count - 1] = Interval(start: previous.start,
                                                    end: max(previous.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    private static func appendByLocalDay(
        start: Double,
        end: Double,
        kcal: Double,
        originalDuration: Double,
        workout: Workout,
        calendar: Calendar,
        into output: inout [OutputSpan]
    ) {
        var cursor = start
        while cursor < end {
            let day = calendar.dateInterval(of: .day, for: Date(timeIntervalSince1970: cursor))
            let dayStart = day?.start.timeIntervalSince1970 ?? cursor
            let dayEnd = day?.end.timeIntervalSince1970 ?? end
            let boundary = dayEnd.isFinite && dayEnd > cursor ? min(end, dayEnd) : end
            let segmentEnd = boundary > cursor ? boundary : end
            let fraction = min(1, max(0, (segmentEnd - cursor) / originalDuration))
            let energy = kcal * fraction
            append(OutputSpan(span: Span(start: cursor, end: segmentEnd, kcal: energy),
                              workout: workout, dayStart: dayStart), into: &output)
            cursor = segmentEnd
        }
    }

    private static func append(_ next: OutputSpan, into output: inout [OutputSpan]) {
        if let previous = output.last,
           previous.span.end == next.span.start,
           previous.workout == next.workout,
           previous.dayStart == next.dayStart {
            output[output.count - 1] = OutputSpan(
                span: Span(start: previous.span.start, end: next.span.end,
                           kcal: previous.span.kcal + next.span.kcal),
                workout: previous.workout,
                dayStart: previous.dayStart
            )
        } else {
            output.append(next)
        }
    }

    private static func split(
        start: Double,
        end: Double,
        kcal: Double,
        calendar: Calendar,
        consume: (String, Double) -> Void
    ) {
        let duration = end - start
        guard duration.isFinite, duration > 0 else { return }
        var cursor = start
        while cursor < end {
            let day = calendar.dateInterval(of: .day, for: Date(timeIntervalSince1970: cursor))
            let dayEnd = day?.end.timeIntervalSince1970 ?? end
            let boundary = dayEnd.isFinite && dayEnd > cursor ? min(end, dayEnd) : end
            let segmentEnd = boundary > cursor ? boundary : end
            let segmentKcal = kcal * ((segmentEnd - cursor) / duration)
            consume(dayKey(for: Date(timeIntervalSince1970: cursor), calendar: calendar), segmentKcal)
            cursor = segmentEnd
        }
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0,
                      components.month ?? 0, components.day ?? 0)
    }
}
