import XCTest
@testable import AfterRayRecall

final class AfterRayLogTests: XCTestCase {
    func testDiagnosticsReportIncludesLogPath() {
        AfterRayLog.install()
        AfterRayLog.info("settings-lab smoke")
        let report = AfterRayLog.diagnosticsReport()
        XCTAssertTrue(report.contains("AfterRay diagnostics"))
        XCTAssertTrue(report.contains(AfterRayLog.fileURL.path))
        XCTAssertTrue(report.contains("settings-lab smoke"))
    }

    func testLogDirectoryIsStable() {
        let first = AfterRayLog.directory
        let second = AfterRayLog.directory
        XCTAssertEqual(first, second)
        XCTAssertEqual(AfterRayLog.fileURL.lastPathComponent, "afterray.log")
    }
}
