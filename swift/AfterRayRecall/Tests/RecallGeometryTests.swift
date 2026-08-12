import XCTest
@testable import AfterRayRecall

final class RecallGeometryTests: XCTestCase {
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
}
