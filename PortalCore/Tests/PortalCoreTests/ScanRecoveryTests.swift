import XCTest
@testable import PortalCore

final class ScanRecoveryTests: XCTestCase {
    func testUnplacedRelocalizationGetsBoundedFreshStart() {
        var p = ScanRecoveryPolicy()
        XCTAssertFalse(p.shouldRestart(.relocalizing, hasDoorway: false, now: 0))
        XCTAssertFalse(p.shouldRestart(.relocalizing, hasDoorway: false, now: 2.9))
        XCTAssertTrue(p.shouldRestart(.relocalizing, hasDoorway: false, now: 3))
        XCTAssertFalse(p.shouldRestart(.relocalizing, hasDoorway: false, now: 100), "do not loop automatic resets")
    }

    func testPlacedDoorwayIsNeverResetAutomatically() {
        var p = ScanRecoveryPolicy()
        XCTAssertFalse(p.shouldRestart(.relocalizing, hasDoorway: true, now: 0))
        XCTAssertFalse(p.shouldRestart(.relocalizing, hasDoorway: true, now: 100))
        XCTAssertFalse(p.didAutomaticallyRestart)
    }

    func testRecoveredTrackingClearsContinuousTimer() {
        var p = ScanRecoveryPolicy()
        _ = p.shouldRestart(.relocalizing, hasDoorway: false, now: 0)
        _ = p.shouldRestart(.normal, hasDoorway: false, now: 2)
        XCTAssertFalse(p.shouldRestart(.relocalizing, hasDoorway: false, now: 2.5))
        XCTAssertFalse(p.shouldRestart(.relocalizing, hasDoorway: false, now: 5))
        XCTAssertTrue(p.shouldRestart(.relocalizing, hasDoorway: false, now: 5.5))
    }

    func testDifficultRoomDoesNotCauseResetLoop() {
        var p = ScanRecoveryPolicy()
        for q in [TrackingQuality.initializing, .insufficientFeatures, .excessiveMotion, .notAvailable] {
            XCTAssertFalse(p.shouldRestart(q, hasDoorway: false, now: 0))
            XCTAssertFalse(p.shouldRestart(q, hasDoorway: false, now: 100))
        }
        XCTAssertFalse(p.didAutomaticallyRestart)
    }

    func testNewManualScanRestoresRecoveryBudget() {
        var p = ScanRecoveryPolicy()
        _ = p.shouldRestart(.relocalizing, hasDoorway: false, now: 0)
        XCTAssertTrue(p.shouldRestart(.relocalizing, hasDoorway: false, now: 3))
        p = ScanRecoveryPolicy()
        XCTAssertFalse(p.shouldRestart(.relocalizing, hasDoorway: false, now: 10))
        XCTAssertTrue(p.shouldRestart(.relocalizing, hasDoorway: false, now: 13))
    }
}
