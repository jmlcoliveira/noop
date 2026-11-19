import XCTest
@testable import Strand

/// Regression coverage for the one-slot follow-up queue used by IntelligenceEngine while a pass owns its
/// lock. The scheduler and durable-debt behavior is covered in `RescoreFollowUpTests`.
final class IntelligenceForcedRescoreRearmTests: XCTestCase {
    func testForcedCallsDuringAnActivePassCoalesceWithoutDroppingRequestSemantics() {
        var queue = RescoreFollowUpQueue()
        for _ in 0..<100 {
            _ = queue.enqueue(RescoreFollowUpRequest(maxDays: 21, skipIfUnchanged: true,
                                                      triggerLabel: "post-offload"))
        }
        _ = queue.enqueue(RescoreFollowUpRequest(maxDays: 4_000,
            triggerLabel: "sleep-wear-history-repair", preserveUnscoredHistory: true))

        let request = queue.take()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(request?.maxDays, 4_000)
        XCTAssertEqual(request?.preserveUnscoredHistory, true)
        XCTAssertEqual(request?.skipIfUnchanged, false,
                       "the repair cannot be skipped by the post-offload fingerprint gate")
        XCTAssertEqual(request?.triggerLabels,
                       ["post-offload", "sleep-wear-history-repair"])
    }
}
