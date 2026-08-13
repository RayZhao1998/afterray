import XCTest
@testable import AfterRayRecall

@MainActor
final class AfterRayControlModelTests: XCTestCase {
    func testToggleUsesDaemonRecordCommandsAndRefreshesStatus() async {
        let daemon = ControlDaemon()
        let model = AfterRayControlModel(daemon: daemon)

        await model.refreshStatus()
        XCTAssertFalse(model.isRecording)
        let started = await model.toggleRecording()
        XCTAssertTrue(started)
        XCTAssertTrue(model.isRecording)
        let stopped = await model.toggleRecording()
        XCTAssertTrue(stopped)
        XCTAssertFalse(model.isRecording)

        let commands = await daemon.recordCommands
        XCTAssertEqual(commands, ["start", "stop"])
    }

    func testSearchTrimsQueryAndReturnsTypedHits() async {
        let daemon = ControlDaemon()
        let model = AfterRayControlModel(daemon: daemon)
        model.searchQuery = "  architecture  "

        await model.search()

        XCTAssertEqual(model.searchHits.map(\.momentId), ["m1"])
        let query = await daemon.lastSearchQuery
        XCTAssertEqual(query, "architecture")
    }

    func testEnsureRecordingStartsOnlyWhenIdle() async {
        let daemon = ControlDaemon()
        let model = AfterRayControlModel(daemon: daemon)

        let first = await model.ensureRecording()
        let second = await model.ensureRecording()
        XCTAssertTrue(first)
        XCTAssertTrue(second)

        let commands = await daemon.recordCommands
        XCTAssertEqual(commands, ["start"])
    }

    func testSystemLockClearsSearchAndStatus() async {
        let daemon = ControlDaemon()
        let model = AfterRayControlModel(daemon: daemon)
        await model.refreshStatus()
        model.searchQuery = "private query"
        await model.search()

        model.clearSensitiveState()

        XCTAssertNil(model.status)
        XCTAssertEqual(model.searchQuery, "")
        XCTAssertTrue(model.searchHits.isEmpty)
        XCTAssertNil(model.message)
    }
}

private actor ControlDaemon: AfterRayDaemonServing {
    var recordingState: DaemonRecordingState = .idle
    var recordCommands: [String] = []
    var lastSearchQuery: String?

    func status() async throws -> DaemonStatus {
        DaemonStatus(
            daemonVersion: "0.1.0",
            protocolVersion: 1,
            schemaVersion: 1,
            recordingState: recordingState,
            activeSessionId: recordingState == .recording ? "s1" : nil
        )
    }

    func recordStart() async throws -> RecordStartResult {
        recordCommands.append("start")
        recordingState = .recording
        return RecordStartResult(sessionId: "s1")
    }

    func recordStop() async throws -> RecordStopResult {
        recordCommands.append("stop")
        recordingState = .idle
        return RecordStopResult(sessionId: "s1")
    }

    func shutdown() async throws -> DaemonShutdownResult {
        DaemonShutdownResult(stopping: true, pid: nil)
    }

    func modelLibrary() async throws -> ModelLibrary {
        ModelLibrary(directory: "/tmp/afterray-models", packs: [])
    }

    func settings() async throws -> AppSettings {
        AppSettings(
            dataDir: "/tmp/afterray-data",
            modelDir: "/tmp/afterray-models",
            recordAudio: true,
            captureIntervalSeconds: 10
        )
    }

    func updateSettings(recordAudio: Bool) async throws -> AppSettings {
        AppSettings(
            dataDir: "/tmp/afterray-data",
            modelDir: "/tmp/afterray-models",
            recordAudio: recordAudio,
            captureIntervalSeconds: 10
        )
    }

    func search(query: String, limit: Int) async throws -> [RecallSearchHit] {
        lastSearchQuery = query
        return [
            RecallSearchHit(
                momentId: "m1",
                sessionId: "s1",
                capturedAtMs: 100,
                source: "ocr",
                text: "Architecture notes",
                score: 1
            )
        ]
    }

    func sessions() async throws -> [RecallSession] { [] }
    func timeline() async throws -> [RecallMoment] { [] }
    func timeline(sinceMs _: Int64) async throws -> [RecallMoment] { [] }
    func moments(sessionID: String) async throws -> [RecallMoment] { [] }
    func recallWindow(sessionID: String, centerMs: Int64, limit: Int) async throws -> [RecallMoment] { [] }
    func artifact(id: String) async throws -> ArtifactPayload {
        ArtifactPayload(id: id, contentType: "application/octet-stream", bytes: Data())
    }
    func setFavorite(momentID: String, favorite: Bool) async throws {}
}
