import Foundation

/// Non-publishing freshness state for the latest readable live-HR sample.
///
/// Wall-clock time is retained for consumers that need to display when the sample arrived. Silence
/// decisions use the monotonic timestamp so device clock changes cannot make a live value go stale
/// early or remain fresh indefinitely.
struct HeartRateFreshness {
    enum TimerAction: Equatable {
        case noReadableSample
        case reschedule(after: TimeInterval)
        case clearHeartRate
    }

    private(set) var lastReadableAt: Date?
    private var lastReadableMonotonicTime: TimeInterval?
    private var timerArmedAtMonotonicTime: TimeInterval?

    /// Record every readable sample. Return a new full silence interval only when the timer's
    /// rearm throttle has elapsed; callers still get the fresh sample timestamp on throttled calls.
    mutating func recordReadableSample(
        at date: Date,
        monotonicTime: TimeInterval,
        silenceInterval: TimeInterval
    ) -> TimeInterval? {
        lastReadableAt = date
        lastReadableMonotonicTime = monotonicTime

        let rearmInterval = max(0, silenceInterval / 10)
        if let timerArmedAtMonotonicTime,
           monotonicTime - timerArmedAtMonotonicTime < rearmInterval {
            return nil
        }

        timerArmedAtMonotonicTime = monotonicTime
        return max(0, silenceInterval)
    }

    /// Decide whether a timer callback may clear the current HR. A callback can be early or can
    /// already be queued when a newer sample arrives, so it must compare against the newest
    /// monotonic sample and schedule only the remaining silence interval.
    mutating func timerFired(
        monotonicTime: TimeInterval,
        silenceInterval: TimeInterval
    ) -> TimerAction {
        guard let lastReadableMonotonicTime else { return .noReadableSample }

        let elapsed = max(0, monotonicTime - lastReadableMonotonicTime)
        let remaining = max(0, silenceInterval) - elapsed
        guard remaining > 0 else {
            timerArmedAtMonotonicTime = nil
            return .clearHeartRate
        }
        return .reschedule(after: remaining)
    }

    /// A source/session reset invalidates both the display timestamp and every pending timer check.
    mutating func reset() {
        lastReadableAt = nil
        lastReadableMonotonicTime = nil
        timerArmedAtMonotonicTime = nil
    }
}
