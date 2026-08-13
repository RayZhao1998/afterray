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

    func testStorageShareTextExplainsTinyAfterRayFootprint() {
        let snapshot = AfterRayStorageSnapshot(
            vaultBytes: 80_000_000,
            modelBytes: 20_000_000,
            runtimeBytes: 0,
            volumeTotal: 1_000_000_000_000,
            volumeFree: 200_000_000_000
        )
        XCTAssertEqual(snapshot.otherBytes, 799_900_000_000)
        XCTAssertTrue(snapshot.diskShareText.contains("less than 0.1%"))
        XCTAssertTrue(snapshot.diskShareText.contains("disk"))
    }

    func testLogDirectoryIsStable() {
        let first = AfterRayLog.directory
        let second = AfterRayLog.directory
        XCTAssertEqual(first, second)
        XCTAssertEqual(AfterRayLog.fileURL.lastPathComponent, "afterray.log")
    }
}
