import AppKit
import XCTest
@testable import AfterRayRecall

final class HistoryDocumentScrollTests: XCTestCase {
    func testTargetOriginAnchorsHighlightInsideViewport() {
        let origin = HistoryDocumentScroll.targetOriginY(
            highlightRect: NSRect(x: 0, y: 700, width: 200, height: 80),
            viewportHeight: 300,
            documentHeight: 1_200
        )

        XCTAssertEqual(origin, 635)
    }

    func testTargetOriginClampsAtDocumentEdges() {
        XCTAssertEqual(
            HistoryDocumentScroll.targetOriginY(
                highlightRect: NSRect(x: 0, y: 10, width: 200, height: 20),
                viewportHeight: 300,
                documentHeight: 1_200
            ),
            0
        )
        XCTAssertEqual(
            HistoryDocumentScroll.targetOriginY(
                highlightRect: NSRect(x: 0, y: 1_150, width: 200, height: 40),
                viewportHeight: 300,
                documentHeight: 1_200
            ),
            900
        )
    }
}
