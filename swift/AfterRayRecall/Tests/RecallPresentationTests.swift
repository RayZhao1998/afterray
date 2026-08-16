import XCTest
@testable import AfterRayRecall

final class RecallPresentationTests: XCTestCase {
    func testTransientLiveStateRemovesHistoryBackdropBeforeBindingSettles() {
        XCTAssertTrue(RecallPresentation.isLive(committed: false, transient: true))
        XCTAssertFalse(
            RecallPresentation.showsHistoryBackdrop(committed: false, transient: true)
        )
    }

    func testTransientHistoryStateKeepsBackdropWhileLeavingNow() {
        XCTAssertFalse(RecallPresentation.isLive(committed: true, transient: false))
        XCTAssertTrue(
            RecallPresentation.showsHistoryBackdrop(committed: true, transient: false)
        )
    }

    func testSettledStateIsUsedOutsideScrubbing() {
        XCTAssertTrue(RecallPresentation.isLive(committed: true, transient: nil))
        XCTAssertFalse(RecallPresentation.isLive(committed: false, transient: nil))
    }
}
