import XCTest
@testable import Strand

@MainActor
final class RescoreFollowUpTests: XCTestCase {
    private var savedDefaults: [String: Any?] = [:]
    private let keys = [
        RescoreBackgroundScheduler.owedKey,
        RescoreBackgroundScheduler.lastPassSecondsKey,
        RescoreBackgroundScheduler.owedTokenKey,
        RescoreBackgroundScheduler.owedAfterCompletedPassKey,
        RescoreBackgroundScheduler.owedRequiresForcedPassKey,
        RescoreBackgroundScheduler.lastAttemptStartedAtKey
    ]

    override func setUp() {
        super.setUp()
        for key in keys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys {
            if let value = savedDefaults[key] ?? nil { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    func testOffloadStormCoalescesToOneLatestScopedRequest() {
        var queue = RescoreFollowUpQueue()
        for index in 0..<100 {
            queue.enqueue(RescoreFollowUpRequest(maxDays: 21, skipIfUnchanged: true,
                                                  triggerLabel: index == 99 ? "latest-offload" : "post-offload"))
        }

        let request = queue.take()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(request?.maxDays, 21)
        XCTAssertTrue(request?.force == true)
        XCTAssertTrue(request?.skipIfUnchanged == true)
        XCTAssertEqual(request?.triggerLabels, ["post-offload", "latest-offload"])
    }

    func testQueuedExplicitEditCannotBeFingerprintSkipped() {
        var queue = RescoreFollowUpQueue()
        queue.enqueue(RescoreFollowUpRequest(maxDays: 21, skipIfUnchanged: true,
                                              triggerLabel: "post-offload"))
        queue.enqueue(RescoreFollowUpRequest(maxDays: 21, skipIfUnchanged: false,
                                              triggerLabel: "baseline-edit"))

        let request = queue.take()
        XCTAssertEqual(request?.skipIfUnchanged, false,
                       "an explicit edit changes scores without changing the raw-data fingerprint")
        XCTAssertEqual(request?.triggerLabels, ["post-offload", "baseline-edit"])
    }

    func testRepairScopeAndCallbacksSurviveCoalescing() {
        var queue = RescoreFollowUpQueue()
        var callbacks = 0
        queue.enqueue(RescoreFollowUpRequest(maxDays: 4_000, triggerLabel: "sleep-wear-history-repair",
                                              preserveUnscoredHistory: true, onPersisted: { callbacks += 1 }))
        queue.enqueue(RescoreFollowUpRequest(maxDays: 21, skipIfUnchanged: true,
                                              triggerLabel: "post-offload", onPersisted: { callbacks += 1 }))

        let request = queue.take()
        XCTAssertEqual(request?.maxDays, 4_000)
        XCTAssertEqual(request?.preserveUnscoredHistory, true)
        XCTAssertEqual(request?.skipIfUnchanged, false)
        XCTAssertEqual(request?.onPersisted.count, 2)
        request?.onPersisted.forEach { $0() }
        XCTAssertEqual(callbacks, 2)
    }

    func testActivePassQueuesOnceThenBackgroundDrainDefersAndForegroundRunsIt() async {
        var queue = RescoreFollowUpQueue()
        var starts = 0
        let activeToken = RescoreBackgroundScheduler.markRescoreOwed(passStarting: true)

        let queued = await RescoreBackgroundScheduler.run(
            isBackground: true, passInProgress: true, log: { _ in }) {
                let firstRequest = queue.enqueue(RescoreFollowUpRequest(maxDays: 21,
                    skipIfUnchanged: true, triggerLabel: "latest-offload"))
                if firstRequest { _ = RescoreBackgroundScheduler.markRescoreOwed() }
            }
        XCTAssertEqual(queued, .queuedBehindRunningPass)
        XCTAssertNotEqual(RescoreBackgroundScheduler.currentOwedToken, activeToken,
                          "the active pass must not settle a newer offload's debt")
        XCTAssertFalse(queue.isEmpty)

        _ = RescoreBackgroundScheduler.markRescoreCompleted(seconds: 1, owedToken: activeToken)
        XCTAssertTrue(RescoreBackgroundScheduler.isOwedAfterCompletedPass)

        let deferred = await RescoreBackgroundScheduler.run(
            isBackground: true, preserveCompletedPassProofOnDefer: true, log: { _ in }) {
            if queue.take() != nil { starts += 1 }
        }
        XCTAssertEqual(deferred, .deferred)
        XCTAssertEqual(starts, 0, "a recent background pass must not immediately chain another heavy pass")
        XCTAssertFalse(queue.isEmpty, "deferred work remains available for processing or foreground entry")
        XCTAssertTrue(RescoreBackgroundScheduler.isOwedAfterCompletedPass,
                      "a duplicate deferral must preserve the completed watermark proof")

        var consumedLabel: String?
        let foreground = await RescoreBackgroundScheduler.run(isBackground: false, log: { _ in }) {
            let request = queue.take()
            consumedLabel = request?.triggerLabel
            if request != nil { starts += 1 }
        }
        XCTAssertEqual(foreground, .ran)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(consumedLabel, "latest-offload")
        XCTAssertTrue(queue.isEmpty)
    }

    func testBackgroundPassInProgressDecisionQueuesInsteadOfRunningAnotherPass() {
        let decision = RescoreBackgroundPolicy.decide(isBackground: true,
            rescoreAlreadyOwed: true, passInProgress: true, secondsSinceLastAttempt: 1)
        XCTAssertEqual(decision, .queueBehindRunningPass)

        let afterPass = RescoreBackgroundPolicy.decide(isBackground: true,
            rescoreAlreadyOwed: true, passInProgress: false, secondsSinceLastAttempt: 1)
        guard case .deferToBackgroundTask = afterPass else {
            return XCTFail("the queued request should wait for background policy after the active pass")
        }

        let afterCooldown = RescoreBackgroundPolicy.decide(isBackground: true,
            rescoreAlreadyOwed: true, passInProgress: false,
            secondsSinceLastAttempt: RescoreBackgroundPolicy.backgroundSpacingSeconds + 1)
        XCTAssertEqual(afterCooldown, .run, "the durable debt eventually becomes eligible")
    }
}
