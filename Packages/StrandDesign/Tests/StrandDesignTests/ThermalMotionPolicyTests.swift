import XCTest
@testable import StrandDesign

/// Thermal policy is tested as a pure snapshot transition so the suite never changes the host's
/// ProcessInfo thermal state, user preferences, or Low Power Mode setting.
final class ThermalMotionPolicyTests: XCTestCase {

    private func policy(
        thermalState: ProcessInfo.ThermalState,
        reduceMotion: Bool = false,
        isLowPower: Bool = false,
        quietMotion: Bool = false,
        windowObscured: Bool = false
    ) -> NoopMotionPolicy {
        NoopMotionPolicy(
            reduceMotion: reduceMotion,
            isLowPower: isLowPower,
            thermalState: thermalState,
            quietMotion: quietMotion,
            windowObscured: windowObscured
        )
    }

    func testNominalAndFairAllowDecorativeMotion() {
        XCTAssertFalse(policy(thermalState: .nominal).poseStill)
        XCTAssertFalse(policy(thermalState: .fair).poseStill)
    }

    func testSeriousAndCriticalThermalPressurePoseMotionStill() {
        XCTAssertTrue(policy(thermalState: .serious).poseStill)
        XCTAssertTrue(policy(thermalState: .critical).poseStill)
    }

    func testThermalTransitionsStopAndRestoreDecorativeMotion() {
        let sequence: [(ProcessInfo.ThermalState, Bool)] = [
            (.nominal, false),
            (.fair, false),
            (.serious, true),
            (.critical, true),
            (.fair, false),
            (.nominal, false),
        ]

        for (thermalState, expectedStill) in sequence {
            XCTAssertEqual(
                policy(thermalState: thermalState).poseStill,
                expectedStill,
                "unexpected gate state for thermal state \(thermalState)"
            )
        }
    }

    func testThermalSignalSharesTheExistingMotionPolicy() {
        XCTAssertTrue(policy(thermalState: .nominal, reduceMotion: true).poseStill)
        XCTAssertTrue(policy(thermalState: .nominal, isLowPower: true).poseStill)
        XCTAssertTrue(policy(thermalState: .nominal, quietMotion: true).poseStill)
        XCTAssertTrue(policy(thermalState: .nominal, windowObscured: true).poseStill)

        // A cool system restores motion only when no other quiet signal remains active.
        XCTAssertFalse(policy(thermalState: .fair).poseStill)
        XCTAssertTrue(policy(thermalState: .fair, isLowPower: true).poseStill)
    }
}
