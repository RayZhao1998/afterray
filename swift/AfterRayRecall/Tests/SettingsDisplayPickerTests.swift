import CoreGraphics
import XCTest

@testable import AfterRayRecall

final class SettingsDisplayPickerTests: XCTestCase {
    func testPreviewFitsLandscapeAndPortraitInsideTheSameCell() {
        let container = CGSize(width: 172, height: 82)

        let landscape = captureDisplayPreviewSize(
            aspectRatio: 16.0 / 9.0,
            container: container
        )
        XCTAssertEqual(landscape.width, 145.78, accuracy: 0.01)
        XCTAssertEqual(landscape.height, 82, accuracy: 0.01)

        let portrait = captureDisplayPreviewSize(
            aspectRatio: 9.0 / 16.0,
            container: container
        )
        XCTAssertEqual(portrait.width, 46.13, accuracy: 0.01)
        XCTAssertEqual(portrait.height, 82, accuracy: 0.01)

        XCTAssertLessThanOrEqual(landscape.width, container.width)
        XCTAssertLessThanOrEqual(portrait.width, container.width)
    }
}
