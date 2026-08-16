import XCTest
@testable import AfterRayRecall

final class HistoryDocumentFollowTests: XCTestCase {
    func testSlotChangeRequestsImmediateFollow() {
        XCTAssertTrue(
            HistoryDocumentFollow.shouldFollow(
                previousSlot: 1,
                currentSlot: 2,
                settleRequested: false
            )
        )
    }

    func testMovementWithinSameSlotDoesNotRequestAnotherFollow() {
        XCTAssertFalse(
            HistoryDocumentFollow.shouldFollow(
                previousSlot: 2,
                currentSlot: 2,
                settleRequested: false
            )
        )
    }

    func testSettleRequestsFinalCorrectionWithinSameSlot() {
        XCTAssertTrue(
            HistoryDocumentFollow.shouldFollow(
                previousSlot: 2,
                currentSlot: 2,
                settleRequested: true
            )
        )
    }

    func testMissingCurrentSlotDoesNotRequestLiveFollow() {
        XCTAssertFalse(
            HistoryDocumentFollow.shouldFollow(
                previousSlot: 2,
                currentSlot: nil,
                settleRequested: false
            )
        )
    }

    func testHighlightBeginningIsAnchoredBelowPinnedHeader() {
        XCTAssertEqual(
            HistoryDocumentFollow.targetOriginY(
                highlightRect: CGRect(x: 0, y: 700, width: 100, height: 80),
                viewportHeight: 300,
                contentHeight: 1_200,
                topInset: 28
            ),
            672
        )
    }

    func testDifferentCardHeightsKeepTheSameTopPosition() {
        let shortCard = CGRect(x: 0, y: 700, width: 100, height: 80)
        let tallCard = CGRect(x: 0, y: 900, width: 100, height: 240)
        let shortOrigin = HistoryDocumentFollow.targetOriginY(
            highlightRect: shortCard,
            viewportHeight: 460,
            contentHeight: 3_000,
            topInset: 28
        )
        let tallOrigin = HistoryDocumentFollow.targetOriginY(
            highlightRect: tallCard,
            viewportHeight: 460,
            contentHeight: 3_000,
            topInset: 28
        )

        XCTAssertEqual(shortCard.minY - shortOrigin, 28)
        XCTAssertEqual(tallCard.minY - tallOrigin, 28)
    }

    func testCardThatFitsRemainsVisibleBelowPinnedHeader() {
        let viewportHeight: CGFloat = 460
        let topInset: CGFloat = 28
        let highlight = CGRect(x: 0, y: 1_000, width: 100, height: 342)
        let origin = HistoryDocumentFollow.targetOriginY(
            highlightRect: highlight,
            viewportHeight: viewportHeight,
            contentHeight: 3_000,
            topInset: topInset
        )

        XCTAssertEqual(origin, 972)
        XCTAssertGreaterThanOrEqual(highlight.minY - origin, topInset)
        XCTAssertLessThanOrEqual(highlight.maxY - origin, viewportHeight)
    }

    func testHighlightTallerThanViewportPrioritisesItsBeginning() {
        let highlight = CGRect(x: 0, y: 1_000, width: 100, height: 500)
        let origin = HistoryDocumentFollow.targetOriginY(
            highlightRect: highlight,
            viewportHeight: 460,
            contentHeight: 3_000,
            topInset: 28
        )

        XCTAssertEqual(origin, 972)
        XCTAssertEqual(highlight.minY - origin, 28)
    }

    func testAnchorClampsToDocumentEdges() {
        XCTAssertEqual(
            HistoryDocumentFollow.targetOriginY(
                highlightRect: CGRect(x: 0, y: 10, width: 100, height: 20),
                viewportHeight: 300,
                contentHeight: 1_200
            ),
            10
        )
        XCTAssertEqual(
            HistoryDocumentFollow.targetOriginY(
                highlightRect: CGRect(x: 0, y: 1_170, width: 100, height: 20),
                viewportHeight: 300,
                contentHeight: 1_200
            ),
            900
        )
    }
}
