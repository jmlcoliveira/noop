import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private struct ReconnectRecoveryOrderingHarness {
    static func main() {
        var recovery = BondLoopStandingConnectRecovery()
        recovery.pauseJustTripped()

        // The exact production helper must refuse to park until both teardown milestones have been noted.
        var teardown = BondLoopStandingConnectRecovery.DisconnectTeardown()
        require(recovery.takeAttemptAfterDisconnect(
            teardown: &teardown,
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: 0) == .none,
            "the initial connect ran before the link-down/characteristic-reset milestones")

        var reversedTeardown = BondLoopStandingConnectRecovery.DisconnectTeardown()
        reversedTeardown.noteCharacteristicsReset()
        reversedTeardown.noteConnectedCleared()
        require(recovery.takeAttemptAfterDisconnect(
            teardown: &reversedTeardown,
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: 0) == .none,
            "characteristic teardown was accepted before the link was marked down")

        teardown.noteConnectedCleared()
        require(recovery.takeAttemptAfterDisconnect(
            teardown: &teardown,
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: 0) == .none,
            "the initial connect ran before characteristics were reset")

        teardown.noteCharacteristicsReset()
        require(recovery.takeAttemptAfterDisconnect(
            teardown: &teardown,
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: 0) == .initial,
            "a just-tripped pause did not receive exactly one immediate parked connect")
        require(recovery.takeAttemptAfterDisconnect(
            teardown: &teardown,
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: 0) == .none,
            "the same disconnect scheduled more than one parked connect")

        // A timeout-loop pause must survive a quick CLIENT_HELLO ack/drop cycle. The first parked connect
        // is still one-shot, and its early drop cannot restart active reconnect before the existing floor.
        var timeoutRecovery = BondLoopStandingConnectRecovery()
        timeoutRecovery.pauseJustTripped(throughHealthyConnection: true)
        var firstTimeoutTeardown = BondLoopStandingConnectRecovery.DisconnectTeardown()
        firstTimeoutTeardown.noteConnectedCleared()
        firstTimeoutTeardown.noteCharacteristicsReset()
        require(timeoutRecovery.takeAttemptAfterDisconnect(
            teardown: &firstTimeoutTeardown,
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: 0) == .initial,
            "a timeout-loop trip did not issue its one first parked connect")
        require(timeoutRecovery.genuineBondAcknowledged() == .preserveTimeoutLoopPause,
                "a genuine bond ack prematurely cleared the timeout-loop pause")
        var quickRedropTeardown = BondLoopStandingConnectRecovery.DisconnectTeardown()
        quickRedropTeardown.noteConnectedCleared()
        quickRedropTeardown.noteCharacteristicsReset()
        require(timeoutRecovery.takeAttemptAfterDisconnect(
            teardown: &quickRedropTeardown,
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: 2) == .none,
            "a quick post-ack drop restarted reconnect before the cooldown")
        require(timeoutRecovery.timeoutLoopPauseNeedsHealthyConnection,
                "a quick post-ack drop cleared the healthy-window latch")
        require(timeoutRecovery.healthyConnectionSurvived(),
                "the healthy connection window did not resolve the timeout-loop pause")
        require(!timeoutRecovery.timeoutLoopPauseNeedsHealthyConnection,
                "the healthy-window resolution left the timeout-loop pause latched")
        require(!timeoutRecovery.healthyConnectionSurvived(),
                "a resolved timeout-loop pause was reported twice")

        // A consumed parked attempt that fails before the floor gets exactly one delayed retry. Once due,
        // the policy consumes the timer and does not schedule polling while CoreBluetooth owns the request.
        var cooldownRetry = BondLoopStandingConnectRecovery.CooldownRetry()
        cooldownRetry.noteProbeStarted()
        let earlyFailureAction = cooldownRetry.failedProbe(
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: 10)
        guard case .after(let cooldownDelay, let cooldownGeneration) = earlyFailureAction else {
            fatalError("a failed parked probe inside the floor did not schedule one cooldown retry")
        }
        require(cooldownDelay == BondLoopStandingConnectRecovery.retryFloorSeconds - 10,
                "the cooldown retry delay did not end at the retry floor")
        require(cooldownRetry.isCurrent(generation: cooldownGeneration),
                "the scheduled cooldown retry did not expose its current generation")
        require(cooldownRetry.timerFired(
            generation: cooldownGeneration,
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: BondLoopStandingConnectRecovery.retryFloorSeconds) == .attemptNow,
            "the one-shot cooldown did not become eligible at the floor")
        require(cooldownRetry.timerFired(
            generation: cooldownGeneration,
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: BondLoopStandingConnectRecovery.retryFloorSeconds) == .none,
            "the consumed cooldown timer scheduled a second attempt without a new failure")

        // A later probe advances the floor while a timer is pending. The old firing reschedules once for
        // that moved floor; without a newer probe, an early firing stops rather than polling.
        var movedFloorRetry = BondLoopStandingConnectRecovery.CooldownRetry()
        let movedFloorInitial = movedFloorRetry.failedProbe(
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: 20)
        guard case .after(_, let movedFloorGeneration) = movedFloorInitial else {
            fatalError("a failed parked probe did not schedule its initial timer")
        }
        movedFloorRetry.noteProbeStarted()
        require(movedFloorRetry.timerFired(
            generation: movedFloorGeneration,
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: 300) == .after(
                delay: BondLoopStandingConnectRecovery.retryFloorSeconds - 300,
                generation: movedFloorGeneration),
            "a newer probe did not move the one-shot retry to its later floor")

        // Manual connect/disconnect, forget, didConnect, and healthy resolution all cancel by invalidating
        // the timer generation. A stale firing or callback from an earlier generation cannot reconnect.
        var cancelledCooldownRetry = BondLoopStandingConnectRecovery.CooldownRetry()
        let cancelledInitial = cancelledCooldownRetry.failedProbe(
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: 30)
        guard case .after(_, let cancelledGeneration) = cancelledInitial else {
            fatalError("a failed parked probe did not schedule before cancellation")
        }
        cancelledCooldownRetry.cancel()
        require(cancelledCooldownRetry.timerFired(
            generation: cancelledGeneration,
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: BondLoopStandingConnectRecovery.retryFloorSeconds) == .none,
            "a cancelled cooldown generation still issued a reconnect")
        let replacement = cancelledCooldownRetry.failedProbe(
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: 31)
        guard case .after(_, let replacementGeneration) = replacement else {
            fatalError("a new failure could not schedule after the prior timer was cancelled")
        }
        require(replacementGeneration != cancelledGeneration,
                "a replacement timer reused the cancelled generation")
        require(cancelledCooldownRetry.timerFired(
            generation: cancelledGeneration,
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: BondLoopStandingConnectRecovery.retryFloorSeconds) == .none,
            "an old timer generation affected its replacement")

        var parkedAttempt = BondLoopStandingConnectRecovery()
        parkedAttempt.parkedConnectWasIssued()
        parkedAttempt.parkedConnectDidConnect()
        require(parkedAttempt.parkedConnectionDidDisconnect(),
                "a connected paused parked attempt was not recognized as consumed on disconnect")
        parkedAttempt.parkedConnectWasIssued()
        require(parkedAttempt.parkedConnectDidFail(),
                "a failed paused parked attempt was not recognized as consumed")
        parkedAttempt.reset()
        require(!parkedAttempt.parkedConnectDidFail()
                    && !parkedAttempt.parkedConnectionDidDisconnect(),
                "reset retained a stale parked-attempt failure")

        // Authentication-refusal give-up retains its established behavior: a genuine bond clears it
        // without waiting for the timeout-loop healthy-window callback.
        var authRefusalRecovery = BondLoopStandingConnectRecovery()
        authRefusalRecovery.pauseJustTripped()
        require(authRefusalRecovery.genuineBondAcknowledged() == .clearPause,
                "a genuine bond stopped clearing an authentication-refusal pause")
        require(!authRefusalRecovery.healthyConnectionSurvived(),
                "an authentication-refusal pause was incorrectly treated as a timeout-loop pause")

        // Explicit user cancellation clears both the first parked attempt and the timeout-loop latch.
        var cancelledTimeoutRecovery = BondLoopStandingConnectRecovery()
        cancelledTimeoutRecovery.pauseJustTripped(throughHealthyConnection: true)
        cancelledTimeoutRecovery.reset()
        require(!cancelledTimeoutRecovery.initialAttemptPending
                    && !cancelledTimeoutRecovery.timeoutLoopPauseNeedsHealthyConnection,
                "manual cancellation left the timeout-loop recovery armed")
        require(cancelledTimeoutRecovery.genuineBondAcknowledged() == .clearPause
                    && !cancelledTimeoutRecovery.healthyConnectionSurvived(),
                "manual cancellation allowed a stale timeout-loop pause to return")

        // A pause that trips on a connected write-refusal stays pending until a later disconnect.
        var connectedRefusal = BondLoopStandingConnectRecovery()
        connectedRefusal.pauseJustTripped()
        var connectedTeardown = BondLoopStandingConnectRecovery.DisconnectTeardown()
        connectedTeardown.noteConnectedCleared()
        connectedTeardown.noteCharacteristicsReset()
        require(connectedRefusal.takeAttemptAfterDisconnect(
            teardown: &connectedTeardown,
            pausedForBondLoop: true,
            connected: true,
            intentionalDisconnect: false,
            secondsSincePauseTripped: 60) == .none,
            "a live link was given a standing connect")
        var laterDisconnect = BondLoopStandingConnectRecovery.DisconnectTeardown()
        laterDisconnect.noteConnectedCleared()
        laterDisconnect.noteCharacteristicsReset()
        require(connectedRefusal.takeAttemptAfterDisconnect(
            teardown: &laterDisconnect,
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: 60) == .initial,
            "a deferred initial connect was lost when the live link later disconnected")

        // A used standing connect is refreshed only after the existing ten-minute floor.
        var refreshRecovery = BondLoopStandingConnectRecovery()
        var refreshTeardown = BondLoopStandingConnectRecovery.DisconnectTeardown()
        refreshTeardown.noteConnectedCleared()
        refreshTeardown.noteCharacteristicsReset()
        require(refreshRecovery.takeAttemptAfterDisconnect(
            teardown: &refreshTeardown,
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: BondLoopStandingConnectRecovery.retryFloorSeconds - 1) == .none,
            "a parked connect refresh escaped the cooldown")
        var eligibleRefresh = BondLoopStandingConnectRecovery.DisconnectTeardown()
        eligibleRefresh.noteConnectedCleared()
        eligibleRefresh.noteCharacteristicsReset()
        require(refreshRecovery.takeAttemptAfterDisconnect(
            teardown: &eligibleRefresh,
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: BondLoopStandingConnectRecovery.retryFloorSeconds) == .retry,
            "a parked connect was not refreshed at the cooldown floor")

        // An explicit teardown never consumes a pending first attempt.
        var intentionalRecovery = BondLoopStandingConnectRecovery()
        intentionalRecovery.pauseJustTripped()
        var intentionalTeardown = BondLoopStandingConnectRecovery.DisconnectTeardown()
        intentionalTeardown.noteConnectedCleared()
        intentionalTeardown.noteCharacteristicsReset()
        require(intentionalRecovery.takeAttemptAfterDisconnect(
            teardown: &intentionalTeardown,
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: true,
            secondsSincePauseTripped: 0) == .none,
            "an intentional disconnect issued a parked connect")
        var afterIntentional = BondLoopStandingConnectRecovery.DisconnectTeardown()
        afterIntentional.noteConnectedCleared()
        afterIntentional.noteCharacteristicsReset()
        require(intentionalRecovery.takeAttemptAfterDisconnect(
            teardown: &afterIntentional,
            pausedForBondLoop: true,
            connected: false,
            intentionalDisconnect: false,
            secondsSincePauseTripped: 0) == .initial,
            "an intentional disconnect consumed the pending first attempt")

        print("reconnect recovery ordering checks passed")
    }
}
