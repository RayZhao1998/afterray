import XCTest
@testable import AfterRayRecall

final class RecallGeometryTests: XCTestCase {
    func testControlBarClearsMacBookCameraSafeArea() {
        XCTAssertEqual(RecallGeometry.controlBarTopPadding(safeAreaTop: 0), 22)
        XCTAssertEqual(RecallGeometry.controlBarTopPadding(safeAreaTop: 32), 44)
    }

    func testOverlaySettingsLeavesRoomForMomentActions() {
        XCTAssertEqual(RecallGeometry.overlaySettingsReservedWidth(), 50)
        XCTAssertEqual(RecallGeometry.detailsMenuTopPadding(chromeTopPadding: 44), 96)
    }

    func testDragLeftMovesForwardAndClamps() {
        XCTAssertEqual(
            RecallGeometry.index(fromDragTranslation: -120, originIndex: 3, count: 10, pointsPerMoment: 50),
            5
        )
        XCTAssertEqual(
            RecallGeometry.index(fromDragTranslation: -1_000, originIndex: 3, count: 10, pointsPerMoment: 50),
            9
        )
    }

    func testDragRightMovesBackwardAndClamps() {
        XCTAssertEqual(
            RecallGeometry.index(fromDragTranslation: 105, originIndex: 6, count: 10, pointsPerMoment: 50),
            4
        )
        XCTAssertEqual(
            RecallGeometry.index(fromDragTranslation: 1_000, originIndex: 6, count: 10, pointsPerMoment: 50),
            0
        )
    }

    func testEmptyTimelineHasNoSelection() {
        XCTAssertNil(RecallGeometry.clampedIndex(0, count: 0))
        XCTAssertNil(RecallGeometry.index(fromDragTranslation: 10, originIndex: 0, count: 0, pointsPerMoment: 50))
    }

    func testLiveTimelinePositionMovesIntoAndBackOutOfHistory() {
        XCTAssertEqual(
            RecallGeometry.timelinePosition(
                fromDragTranslation: 54,
                originPosition: 4,
                momentCount: 4,
                pointsPerMoment: 54
            ),
            3
        )
        XCTAssertEqual(
            RecallGeometry.timelinePosition(
                fromDragTranslation: -54,
                originPosition: 3,
                momentCount: 4,
                pointsPerMoment: 54
            ),
            4
        )
    }

    func testRightwardScrollImmediatelyEntersHistoryFromLive() {
        XCTAssertEqual(RecallGeometry.liveScrollStep(delta: 0.1), -1)
        XCTAssertNil(RecallGeometry.liveScrollStep(delta: -0.1))
    }

    func testScrollDeltaIsBoundedAndDrainedAcrossDisplayFrames() {
        let accumulated = RecallGeometry.accumulatedScrollDelta(
            current: 80,
            incoming: 400
        )
        XCTAssertEqual(accumulated, 160)

        let firstFrame = RecallGeometry.drainScrollDelta(accumulated)
        XCTAssertEqual(firstFrame.emitted, 40)
        XCTAssertEqual(firstFrame.remaining, 120)

        let reverseFrame = RecallGeometry.drainScrollDelta(-95)
        XCTAssertEqual(reverseFrame.emitted, -40)
        XCTAssertEqual(reverseFrame.remaining, -55)
    }
}
