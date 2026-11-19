import XCTest
@testable import StrandDesign

/// The chart's axis must belong to the selected window, not to whichever query result arrived last.
final class OverviewHRChartDomainStabilityTests: XCTestCase {

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func query(
        context: String = "hr|day-1|owned|device-a",
        from: Int = 32_100,
        to: Int = 34_200,
        refreshSequence: Int = 0,
        interactionActive: Bool = false,
        pageActive: Bool = true
    ) -> OverviewHRChart.QueryIdentity {
        OverviewHRChart.QueryIdentity(
            context: context,
            from: from,
            to: to,
            refreshSequence: refreshSequence,
            interactionActive: interactionActive,
            pageActive: pageActive
        )
    }

    func testZoomDomainStaysFixedAsLoadedPointsChangeOrGapOut() {
        let day = date(0)...date(86_400)
        let zoom = date(32_100)...date(34_200)
        let beforeQuery = [TrendPoint(date: date(0), value: 60), TrendPoint(date: date(86_000), value: 70)]
        let afterQuery = [TrendPoint(date: date(32_150), value: 90), TrendPoint(date: date(34_150), value: 80)]

        XCTAssertEqual(
            OverviewHRChart.visibleDomain(points: beforeQuery, xRange: day, zoomDomain: zoom),
            zoom
        )
        XCTAssertEqual(
            OverviewHRChart.visibleDomain(points: afterQuery, xRange: day, zoomDomain: zoom),
            zoom
        )
        XCTAssertEqual(
            OverviewHRChart.visibleDomain(points: [], xRange: day, zoomDomain: zoom),
            zoom,
            "an honest empty gap must keep the requested axis instead of collapsing it"
        )
    }

    func testUnzoomedExplicitDayStaysVisibleAcrossDataGaps() {
        let day = date(0)...date(86_400)
        let narrowData = [TrendPoint(date: date(18_000), value: 60), TrendPoint(date: date(20_000), value: 70)]

        XCTAssertEqual(
            OverviewHRChart.visibleDomain(points: narrowData, xRange: day, zoomDomain: nil),
            day
        )
        XCTAssertEqual(
            OverviewHRChart.visibleDomain(points: [], xRange: day, zoomDomain: nil),
            day
        )
    }

    func testQueryIdentityOnlyCommitsForCurrentUncancelledWindowAndPhase() {
        let current = query()
        XCTAssertTrue(current.mayApplyResult(to: current, isCancelled: false))
        XCTAssertFalse(current.mayApplyResult(to: current, isCancelled: true))
        XCTAssertFalse(current.mayApplyResult(to: query(to: 34_201), isCancelled: false))
        XCTAssertFalse(current.mayApplyResult(to: query(context: "hrv|day-1|owned|device-a"), isCancelled: false))
        XCTAssertFalse(current.mayApplyResult(to: query(interactionActive: true), isCancelled: false))
        XCTAssertFalse(current.mayApplyResult(to: query(pageActive: false), isCancelled: false))

        let duringGesture = query(interactionActive: true)
        let gestureEnded = query(interactionActive: false)
        XCTAssertFalse(duringGesture.mayApplyResult(to: gestureEnded, isCancelled: false))
        XCTAssertTrue(gestureEnded.mayApplyResult(to: gestureEnded, isCancelled: false),
                      "the gesture-end identity must be eligible for the final domain query")
    }

    func testQueryDebounceAppliesToSameContextZoomButNotContextChanges() {
        let resolved = query()
        let zoomWindow = query(from: 32_200, to: 33_000)
        let otherMetric = query(context: "hrv|day-1|owned|device-a")

        XCTAssertFalse(resolved.shouldDebounceReload(after: nil, hasStartedLoad: true))
        XCTAssertFalse(resolved.shouldDebounceReload(after: resolved, hasStartedLoad: false))
        XCTAssertTrue(zoomWindow.shouldDebounceReload(after: resolved, hasStartedLoad: true))
        XCTAssertFalse(otherMetric.shouldDebounceReload(after: resolved, hasStartedLoad: true))
        XCTAssertFalse(query(pageActive: false).shouldDebounceReload(after: resolved, hasStartedLoad: true))

        let duringGesture = query(interactionActive: true)
        let gestureEnded = query(interactionActive: false)
        XCTAssertTrue(duringGesture.shouldDebounceReload(after: resolved, hasStartedLoad: true))
        XCTAssertFalse(duringGesture.mayApplyResult(to: gestureEnded, isCancelled: false))
        XCTAssertTrue(gestureEnded.mayApplyResult(to: gestureEnded, isCancelled: false),
                      "the final settled identity must run even if the last pinch frame didn't change its second bounds")
    }

    func testLoadedPlotCanBeRetainedOnlyForSameContextWithRecords() {
        let context = "hr|day-1|owned|device-a"
        XCTAssertTrue(OverviewHRChart.shouldRetainSeries(
            previousContext: context, currentContext: context, hasPoints: true
        ), "window-only zoom/pan keeps the last resolved samples while the new range loads")
        XCTAssertFalse(OverviewHRChart.shouldRetainSeries(
            previousContext: context, currentContext: "hrv|day-1|owned|device-a", hasPoints: true
        ), "a metric change cannot show heart-rate records under an HRV label")
        XCTAssertFalse(OverviewHRChart.shouldRetainSeries(
            previousContext: context, currentContext: context, hasPoints: false
        ), "an empty query cannot leave old records painted inside a true gap")
    }
}
