import Foundation

/// Pure lifecycle gate for the first parked reconnect after a bond-loop pause.
///
/// The pause can trip either while handling a disconnect or while an encrypted write is still being
/// rejected on a live link. In both cases, the first standing connect belongs after disconnect state and
/// characteristic teardown have completed. Keeping that ordering here makes it testable without
/// CoreBluetooth and keeps the retry floor separate from the one initial request.
struct BondLoopStandingConnectRecovery {
    enum Attempt: Equatable {
        case none
        case initial
        case retry
    }

    enum BondAcknowledgement: Equatable {
        case clearPause
        case preserveTimeoutLoopPause
    }

    /// Pure one-shot timer policy for a paused CoreBluetooth request that was consumed and failed before
    /// the retry floor. It never polls: one callback either consumes the due attempt, reschedules only if a
    /// newer probe moved the floor, or becomes stale after cancellation.
    struct CooldownRetry {
        enum Action: Equatable {
            case none
            case attemptNow
            case after(delay: TimeInterval, generation: Int)
        }

        private(set) var generation = 0
        private(set) var probeGeneration = 0
        private(set) var isPending = false
        private var scheduledProbeGeneration = 0

        mutating func noteProbeStarted() {
            probeGeneration &+= 1
        }

        mutating func failedProbe(pausedForBondLoop: Bool,
                                  connected: Bool,
                                  intentionalDisconnect: Bool,
                                  secondsSincePauseTripped: TimeInterval?) -> Action {
            guard pausedForBondLoop, !connected, !intentionalDisconnect else { return .none }
            guard let elapsed = secondsSincePauseTripped else { return .attemptNow }
            guard elapsed < BondLoopStandingConnectRecovery.retryFloorSeconds else { return .attemptNow }
            guard !isPending else { return .none }
            generation &+= 1
            isPending = true
            scheduledProbeGeneration = probeGeneration
            return .after(delay: BondLoopStandingConnectRecovery.retryFloorSeconds - elapsed,
                          generation: generation)
        }

        func isCurrent(generation token: Int) -> Bool {
            isPending && token == generation
        }

        mutating func timerFired(generation token: Int,
                                 pausedForBondLoop: Bool,
                                 connected: Bool,
                                 intentionalDisconnect: Bool,
                                 secondsSincePauseTripped: TimeInterval?) -> Action {
            guard isPending, token == generation else { return .none }
            guard pausedForBondLoop, !connected, !intentionalDisconnect else {
                isPending = false
                return .none
            }
            guard let elapsed = secondsSincePauseTripped else {
                isPending = false
                return .attemptNow
            }
            if elapsed >= BondLoopStandingConnectRecovery.retryFloorSeconds {
                isPending = false
                return .attemptNow
            }
            // A new paused probe re-stamped the floor after this one-shot was scheduled. Follow that new
            // floor once; if time moved backwards without a newer probe, stop instead of polling.
            guard probeGeneration != scheduledProbeGeneration else {
                isPending = false
                return .none
            }
            scheduledProbeGeneration = probeGeneration
            return .after(delay: BondLoopStandingConnectRecovery.retryFloorSeconds - elapsed,
                          generation: generation)
        }

        mutating func cancel() {
            isPending = false
            generation &+= 1
        }
    }

    struct DisconnectTeardown {
        private(set) var connectedWasCleared = false
        private(set) var characteristicsWereReset = false
        private(set) var attemptWasTaken = false

        mutating func noteConnectedCleared() {
            connectedWasCleared = true
        }

        mutating func noteCharacteristicsReset() {
            // Preserve the ordering contract in the seam itself: characteristic teardown only counts once
            // the link has already been marked down.
            guard connectedWasCleared else { return }
            characteristicsWereReset = true
        }

        fileprivate mutating func takeAttempt() {
            attemptWasTaken = true
        }

        fileprivate var isComplete: Bool {
            connectedWasCleared && characteristicsWereReset && !attemptWasTaken
        }
    }

    static let retryFloorSeconds: TimeInterval = 10 * 60

    private(set) var initialAttemptPending = false
    /// A timeout-loop pause is stronger than an authentication-refusal pause: a CLIENT_HELLO ack proves
    /// the bond, but the same link still has to survive BLEManager's existing healthy-connection window
    /// before auto-reconnect can resume. Authentication-refusal pauses leave this false and still clear
    /// immediately when a genuine bond succeeds.
    private(set) var timeoutLoopPauseNeedsHealthyConnection = false
    private(set) var parkedAttemptOutstanding = false
    private(set) var parkedConnectionEstablished = false

    mutating func parkedConnectWasIssued() {
        parkedAttemptOutstanding = true
        parkedConnectionEstablished = false
    }

    mutating func parkedConnectDidConnect() {
        guard parkedAttemptOutstanding else { return }
        parkedAttemptOutstanding = false
        parkedConnectionEstablished = true
    }

    mutating func parkedConnectDidFail() -> Bool {
        guard parkedAttemptOutstanding else { return false }
        parkedAttemptOutstanding = false
        return true
    }

    mutating func parkedConnectionDidDisconnect() -> Bool {
        guard parkedConnectionEstablished else { return false }
        parkedConnectionEstablished = false
        return true
    }

    mutating func pauseJustTripped(throughHealthyConnection: Bool = false) {
        initialAttemptPending = true
        timeoutLoopPauseNeedsHealthyConnection = timeoutLoopPauseNeedsHealthyConnection || throughHealthyConnection
    }

    mutating func reset() {
        initialAttemptPending = false
        timeoutLoopPauseNeedsHealthyConnection = false
        parkedAttemptOutstanding = false
        parkedConnectionEstablished = false
    }

    /// A genuine bond clears an authentication-refusal pause. A timeout-loop pause remains latched until
    /// the same connection passes the caller's healthy-connection window. Either way, its one initial park
    /// has been used (or superseded by this live bond) and cannot be replayed after a quick drop.
    mutating func genuineBondAcknowledged() -> BondAcknowledgement {
        initialAttemptPending = false
        return timeoutLoopPauseNeedsHealthyConnection ? .preserveTimeoutLoopPause : .clearPause
    }

    /// Called only by the generation-checked healthy-connection timer. Returns true exactly when that
    /// window resolves a timeout-loop pause; auth-refusal pauses are not cleared by this path.
    mutating func healthyConnectionSurvived() -> Bool {
        guard timeoutLoopPauseNeedsHealthyConnection else { return false }
        timeoutLoopPauseNeedsHealthyConnection = false
        initialAttemptPending = false
        parkedAttemptOutstanding = false
        parkedConnectionEstablished = false
        return true
    }

    /// Returns the one action due after this disconnect's teardown. The initial request bypasses the
    /// retry floor because it has not yet been issued; subsequent refreshes remain rate-limited.
    mutating func takeAttemptAfterDisconnect(
        teardown: inout DisconnectTeardown,
        pausedForBondLoop: Bool,
        connected: Bool,
        intentionalDisconnect: Bool,
        secondsSincePauseTripped: TimeInterval?
    ) -> Attempt {
        guard teardown.isComplete else { return .none }
        let isInitial = initialAttemptPending
        let elapsed = isInitial ? nil : secondsSincePauseTripped
        guard Self.shouldAttempt(pausedForBondLoop: pausedForBondLoop,
                                 connected: connected,
                                 intentionalDisconnect: intentionalDisconnect,
                                 secondsSincePauseTripped: elapsed) else { return .none }
        teardown.takeAttempt()
        if isInitial {
            initialAttemptPending = false
            return .initial
        }
        return .retry
    }

    /// Shared cooldown gate used by other paused reconnect callbacks that already run after disconnect.
    static func shouldAttempt(pausedForBondLoop: Bool,
                              connected: Bool,
                              intentionalDisconnect: Bool,
                              secondsSincePauseTripped: TimeInterval?) -> Bool {
        guard pausedForBondLoop, !connected, !intentionalDisconnect else { return false }
        guard let secondsSincePauseTripped else { return true }
        return secondsSincePauseTripped >= retryFloorSeconds
    }
}
