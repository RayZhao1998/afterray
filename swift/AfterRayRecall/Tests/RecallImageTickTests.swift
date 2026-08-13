import XCTest
@testable import AfterRayRecall

final class RecallImageTickTests: XCTestCase {
    func testFirstRequestStartsATickImmediately() {
        var tick = RecallImageTick()

        XCTAssertEqual(tick.request("A"), .start("A"))
        XCTAssertEqual(tick.displayedArtifactID, "A")
        XCTAssertNil(tick.nextTickPosition)
        XCTAssertTrue(tick.isUpdating)
        XCTAssertTrue(tick.isThrottling)
    }

    func testBusyRequestsOverwriteNextTickPosition() {
        var tick = RecallImageTick()
        _ = tick.request("A")

        XCTAssertEqual(tick.request("B"), .none)
        XCTAssertEqual(tick.request("C"), .none)
        XCTAssertEqual(tick.displayedArtifactID, "A")
        XCTAssertEqual(tick.nextTickPosition, "C")
    }

    func testRequestingTheDisplayedImageClearsAPendingTick() {
        var tick = RecallImageTick()
        _ = tick.request("A")
        _ = tick.request("B")

        XCTAssertEqual(tick.request("A"), .none)
        XCTAssertNil(tick.nextTickPosition)
        XCTAssertEqual(tick.displayedArtifactID, "A")
    }

    func testThrottleEndWaitsForTheInFlightUpdate() {
        var tick = RecallImageTick()
        _ = tick.request("A")
        _ = tick.request("B")

        XCTAssertEqual(tick.throttleEnded(), .none)
        XCTAssertFalse(tick.isThrottling)
        XCTAssertTrue(tick.isUpdating)
        XCTAssertEqual(tick.nextTickPosition, "B")
        XCTAssertEqual(tick.displayedArtifactID, "A")
    }

    func testUpdateFinishWaitsForTheThrottleWindow() {
        var tick = RecallImageTick()
        _ = tick.request("A")
        _ = tick.request("B")

        XCTAssertEqual(tick.updateFinished(for: "A"), .none)
        XCTAssertFalse(tick.isUpdating)
        XCTAssertTrue(tick.isThrottling)
        XCTAssertEqual(tick.nextTickPosition, "B")
        XCTAssertEqual(tick.displayedArtifactID, "A")
    }

    func testTakingNextTickStartsTheFollowingWindow() {
        var tick = RecallImageTick()
        _ = tick.request("A")
        _ = tick.request("B")
        _ = tick.request("C")
        _ = tick.updateFinished(for: "A")

        XCTAssertEqual(tick.throttleEnded(), .start("C"))
        XCTAssertEqual(tick.displayedArtifactID, "C")
        XCTAssertNil(tick.nextTickPosition)
        XCTAssertTrue(tick.isUpdating)
        XCTAssertTrue(tick.isThrottling)
    }

    func testIdleAfterBothWindowsClearWithNoPendingPosition() {
        var tick = RecallImageTick()
        _ = tick.request("A")
        _ = tick.updateFinished(for: "A")
        XCTAssertEqual(tick.throttleEnded(), .none)

        XCTAssertFalse(tick.isUpdating)
        XCTAssertFalse(tick.isThrottling)
        XCTAssertNil(tick.nextTickPosition)
        XCTAssertEqual(tick.request("B"), .start("B"))
    }

    func testStaleUpdateFinishIsIgnored() {
        var tick = RecallImageTick()
        _ = tick.request("A")
        _ = tick.updateFinished(for: "A")
        _ = tick.throttleEnded()
        _ = tick.request("B")

        XCTAssertEqual(tick.updateFinished(for: "A"), .none)
        XCTAssertEqual(tick.displayedArtifactID, "B")
        XCTAssertTrue(tick.isUpdating)
    }
}
