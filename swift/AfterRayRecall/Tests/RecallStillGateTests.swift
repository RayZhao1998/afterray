import XCTest
@testable import AfterRayRecall

final class RecallStillGateTests: XCTestCase {
    func testIntervalIsOneHundredFiftyMilliseconds() {
        XCTAssertEqual(RecallStillGate.intervalMilliseconds, 150)
        XCTAssertEqual(
            RecallStillGate.animationDuration,
            TimeInterval(RecallStillGate.intervalMilliseconds) / 1_000,
            accuracy: 0.000_001
        )
    }

    func testFirstReadyFrameStaysBusyUntilCommitSettle() {
        var gate = RecallStillGate()

        XCTAssertEqual(gate.request("A"), .needFrame("A"))
        XCTAssertEqual(gate.phase, .loading)
        XCTAssertEqual(gate.frameReady("A"), .settle("A"))
        XCTAssertNil(gate.currentID)
        XCTAssertEqual(gate.phase, .loading)
        XCTAssertTrue(gate.isBusy)

        XCTAssertEqual(gate.commitSettle("A"), .none)
        XCTAssertEqual(gate.currentID, "A")
        XCTAssertEqual(gate.phase, .idle)
        XCTAssertFalse(gate.isBusy)
    }

    func testRequestsDuringFirstSettleStayPendingUntilCommit() {
        var gate = RecallStillGate()
        _ = gate.request("A")
        _ = gate.frameReady("A")

        XCTAssertEqual(gate.request("B"), .none)
        XCTAssertEqual(gate.request("C"), .none)
        XCTAssertEqual(gate.pendingID, "C")
        XCTAssertEqual(gate.phase, .loading)

        XCTAssertEqual(gate.commitSettle("A"), .needFrame("C"))
        XCTAssertEqual(gate.currentID, "A")
        XCTAssertEqual(gate.targetID, "C")
        XCTAssertEqual(gate.phase, .loading)
    }

    func testIdleRequestForTheCurrentFrameIsIgnored() {
        var gate = RecallStillGate()
        _ = gate.request("A")
        _ = gate.frameReady("A")
        _ = gate.commitSettle("A")

        XCTAssertEqual(gate.request("A"), .none)
        XCTAssertNil(gate.pendingID)
    }

    func testRequestsDuringATransitionOnlyKeepTheLatestPending() {
        var gate = RecallStillGate()
        _ = gate.request("A")
        _ = gate.frameReady("A")
        _ = gate.commitSettle("A")
        _ = gate.request("B")
        _ = gate.frameReady("B")

        for id in ["C", "D", "E", "F"] {
            XCTAssertEqual(gate.request(id), .none, "\(id) must wait for the in-flight fade")
            XCTAssertEqual(gate.phase, .transitioning)
            XCTAssertEqual(gate.targetID, "B")
        }
        XCTAssertEqual(gate.pendingID, "F")
    }

    func testSecondFrameTransitionsAndBlocksInserts() {
        var gate = RecallStillGate()
        _ = gate.request("A")
        _ = gate.frameReady("A")
        _ = gate.commitSettle("A")

        XCTAssertEqual(gate.request("B"), .needFrame("B"))
        XCTAssertEqual(gate.frameReady("B"), .transition(to: "B"))
        XCTAssertEqual(gate.phase, .transitioning)
        XCTAssertEqual(gate.currentID, "A")
        XCTAssertEqual(gate.targetID, "B")

        XCTAssertEqual(gate.request("C"), .none)
        XCTAssertEqual(gate.request("D"), .none)
        XCTAssertEqual(gate.pendingID, "D")
        XCTAssertEqual(gate.targetID, "B")
    }

    func testTransitionEndStartsThePendingFlyIn() {
        var gate = RecallStillGate()
        _ = gate.request("A")
        _ = gate.frameReady("A")
        _ = gate.commitSettle("A")
        _ = gate.request("B")
        _ = gate.frameReady("B")
        _ = gate.request("C")
        _ = gate.request("D")

        XCTAssertEqual(gate.transitionFinished(), .needFrame("D"))
        XCTAssertEqual(gate.currentID, "B")
        XCTAssertEqual(gate.targetID, "D")
        XCTAssertEqual(gate.phase, .loading)
        XCTAssertNil(gate.pendingID)
        XCTAssertEqual(gate.frameReady("D"), .transition(to: "D"))
    }

    func testReadyFrameIsShownEvenWhenSomethingNewerIsPending() {
        var gate = RecallStillGate()
        _ = gate.request("A")
        _ = gate.frameReady("A")
        _ = gate.commitSettle("A")
        _ = gate.request("B")
        _ = gate.request("C")

        XCTAssertEqual(gate.frameReady("B"), .transition(to: "B"))
        XCTAssertEqual(gate.phase, .transitioning)
        XCTAssertEqual(gate.targetID, "B")
        XCTAssertEqual(gate.pendingID, "C")
        XCTAssertEqual(gate.transitionFinished(), .needFrame("C"))
    }

    func testRequestingTheInFlightTargetClearsPending() {
        var gate = RecallStillGate()
        _ = gate.request("A")
        _ = gate.frameReady("A")
        _ = gate.commitSettle("A")
        _ = gate.request("B")
        _ = gate.frameReady("B")
        _ = gate.request("C")

        XCTAssertEqual(gate.request("B"), .none)
        XCTAssertNil(gate.pendingID)
        XCTAssertEqual(gate.transitionFinished(), .none)
        XCTAssertEqual(gate.currentID, "B")
        XCTAssertEqual(gate.phase, .idle)
    }

    func testFailedLoadTakesPending() {
        var gate = RecallStillGate()
        _ = gate.request("A")
        _ = gate.frameReady("A")
        _ = gate.commitSettle("A")
        _ = gate.request("B")
        _ = gate.request("C")

        XCTAssertEqual(gate.loadFailed("B"), .needFrame("C"))
        XCTAssertEqual(gate.targetID, "C")
        XCTAssertEqual(gate.phase, .loading)
    }

    func testStaleFrameReadyIsIgnored() {
        var gate = RecallStillGate()
        _ = gate.request("A")
        _ = gate.frameReady("A")
        _ = gate.commitSettle("A")
        _ = gate.request("B")
        _ = gate.frameReady("B")

        XCTAssertEqual(gate.frameReady("A"), .ignore)
        XCTAssertEqual(gate.phase, .transitioning)
        XCTAssertEqual(gate.targetID, "B")
    }
}
