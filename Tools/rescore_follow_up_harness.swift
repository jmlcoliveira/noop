import Foundation

@main
struct RescoreFollowUpHarness {
    @MainActor
    static func main() async {
        let keys = [
            RescoreBackgroundScheduler.owedKey,
            RescoreBackgroundScheduler.lastPassSecondsKey,
            RescoreBackgroundScheduler.owedTokenKey,
            RescoreBackgroundScheduler.owedAfterCompletedPassKey,
            RescoreBackgroundScheduler.owedRequiresForcedPassKey,
            RescoreBackgroundScheduler.lastAttemptStartedAtKey
        ]
        var saved: [String: Any] = [:]
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        defer {
            for key in keys {
                if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }

        checkStormCoalesces()
        checkEditAndRepairSemantics()
        checkForcedEditDebtSurvivesCompletedPass()
        await checkBackgroundQueueAndDrain()
        checkPolicyCooldown()
        print("rescore follow-up checks passed")
    }

    private static func checkStormCoalesces() {
        var queue = RescoreFollowUpQueue()
        for index in 0..<100 {
            _ = queue.enqueue(RescoreFollowUpRequest(maxDays: 21, skipIfUnchanged: true,
                triggerLabel: index == 99 ? "latest-offload" : "post-offload"))
        }
        guard let request = queue.take() else { fatalError("offload storm lost its request") }
        precondition(queue.isEmpty)
        precondition(request.force)
        precondition(request.skipIfUnchanged)
        precondition(request.maxDays == 21)
        precondition(request.triggerLabels == ["post-offload", "latest-offload"])
    }

    private static func checkEditAndRepairSemantics() {
        var editQueue = RescoreFollowUpQueue()
        _ = editQueue.enqueue(RescoreFollowUpRequest(maxDays: 21, skipIfUnchanged: true,
            triggerLabel: "post-offload"))
        _ = editQueue.enqueue(RescoreFollowUpRequest(maxDays: 21, skipIfUnchanged: false,
            triggerLabel: "baseline-edit"))
        guard let edit = editQueue.take() else { fatalError("edit request was lost") }
        precondition(!edit.skipIfUnchanged, "an explicit edit cannot be fingerprint-skipped")
        precondition(edit.triggerLabels == ["post-offload", "baseline-edit"])

        var repairQueue = RescoreFollowUpQueue()
        var callbacks = 0
        _ = repairQueue.enqueue(RescoreFollowUpRequest(maxDays: 4_000,
            triggerLabel: "sleep-wear-history-repair", preserveUnscoredHistory: true,
            onPersisted: { callbacks += 1 }))
        _ = repairQueue.enqueue(RescoreFollowUpRequest(maxDays: 21, skipIfUnchanged: true,
            triggerLabel: "post-offload", onPersisted: { callbacks += 1 }))
        guard let repair = repairQueue.take() else { fatalError("repair request was lost") }
        precondition(repair.maxDays == 4_000)
        precondition(repair.preserveUnscoredHistory)
        precondition(!repair.skipIfUnchanged)
        precondition(repair.onPersisted.count == 2)
        repair.onPersisted.forEach { $0() }
        precondition(callbacks == 2, "all persistence callbacks must run after the merged pass")
    }

    @MainActor
    private static func checkForcedEditDebtSurvivesCompletedPass() {
        let activeToken = RescoreBackgroundScheduler.markRescoreOwed(passStarting: true)
        RescoreBackgroundScheduler.requireForcedRescoreForCurrentDebt()
        _ = RescoreBackgroundScheduler.markRescoreOwed(requiresForcedPass: true)
        _ = RescoreBackgroundScheduler.markRescoreCompleted(seconds: 1, owedToken: activeToken)
        precondition(RescoreBackgroundScheduler.isOwedAfterCompletedPass)
        precondition(RescoreBackgroundScheduler.isOwedRequiresForcedPass,
                     "a completed watermark cannot prove a scoring-setting edit was applied")
        precondition(!RescoreBackgroundScheduler.settleCompletedPassDebtIfUnchanged(),
                     "a fingerprint-only gate must leave explicit edit debt outstanding")

        let forcedPassToken = RescoreBackgroundScheduler.markRescoreOwed(
            passStarting: true, requiresForcedPass: true)
        precondition(RescoreBackgroundScheduler.markRescoreCompleted(
            seconds: 1, owedToken: forcedPassToken))
        precondition(!RescoreBackgroundScheduler.isRescoreOwed)
        precondition(!RescoreBackgroundScheduler.isOwedRequiresForcedPass,
                     "the forced requirement clears when the forced pass settles its debt")
    }

    @MainActor
    private static func checkBackgroundQueueAndDrain() async {
        var queue = RescoreFollowUpQueue()
        var heavyPasses = 0
        let activeToken = RescoreBackgroundScheduler.markRescoreOwed(passStarting: true)
        let queued = await RescoreBackgroundScheduler.run(
            isBackground: true, passInProgress: true, log: { _ in }) {
                if queue.enqueue(RescoreFollowUpRequest(maxDays: 21, skipIfUnchanged: true,
                                                        triggerLabel: "latest-offload")) {
                    _ = RescoreBackgroundScheduler.markRescoreOwed()
                }
            }
        precondition(queued == .queuedBehindRunningPass)
        precondition(RescoreBackgroundScheduler.currentOwedToken != activeToken,
                     "the active pass must not settle a newer input's debt")
        precondition(!queue.isEmpty)

        _ = RescoreBackgroundScheduler.markRescoreCompleted(seconds: 1, owedToken: activeToken)
        precondition(RescoreBackgroundScheduler.isOwedAfterCompletedPass)

        let backgroundDrain = await RescoreBackgroundScheduler.run(
            isBackground: true, preserveCompletedPassProofOnDefer: true, log: { _ in }) {
            if queue.take() != nil { heavyPasses += 1 }
        }
        precondition(backgroundDrain == .deferred)
        precondition(heavyPasses == 0, "an active background pass must not immediately chain another pass")
        precondition(!queue.isEmpty, "deferred request must remain queued")
        precondition(RescoreBackgroundScheduler.isOwedAfterCompletedPass,
                     "the duplicate deferral must preserve the completed watermark proof")

        var consumedLabel: String?
        let foregroundDrain = await RescoreBackgroundScheduler.run(isBackground: false, log: { _ in }) {
            let request = queue.take()
            consumedLabel = request?.triggerLabel
            if request != nil { heavyPasses += 1 }
        }
        precondition(foregroundDrain == .ran)
        precondition(heavyPasses == 1)
        precondition(consumedLabel == "latest-offload")
        precondition(queue.isEmpty)
    }

    private static func checkPolicyCooldown() {
        precondition(RescoreBackgroundPolicy.decide(isBackground: true, rescoreAlreadyOwed: true,
            passInProgress: true, secondsSinceLastAttempt: 1) == .queueBehindRunningPass)
        if case .deferToBackgroundTask = RescoreBackgroundPolicy.decide(isBackground: true,
            rescoreAlreadyOwed: true, passInProgress: false, secondsSinceLastAttempt: 1) {
            // Expected: no immediate background chain after the active pass.
        } else {
            fatalError("a recent queued pass should defer to background processing")
        }
        precondition(RescoreBackgroundPolicy.decide(isBackground: true, rescoreAlreadyOwed: true,
            passInProgress: false,
            secondsSinceLastAttempt: RescoreBackgroundPolicy.backgroundSpacingSeconds + 1) == .run,
            "the queued request must eventually become eligible")
    }
}
