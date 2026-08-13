import Foundation
import XCTest
@testable import AfterRayRecall

final class DaemonWireTests: XCTestCase {
    func testTimelineRequestMatchesRustShape() throws {
        let data = try JSONEncoder().encode(WireRequest(type: "timeline_list"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "timeline_list")
        XCTAssertNil(json["session_id"])
    }

    func testTimelineSinceRequestMatchesRustShape() throws {
        let data = try JSONEncoder().encode(WireRequest(type: "timeline_since", sinceMs: 42))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "timeline_since")
        XCTAssertEqual(json["since_ms"] as? Int, 42)
    }

    func testRecallWindowRequestMatchesRustShape() throws {
        let request = WireRequest(type: "recall_window", sessionID: "session-1", centerMs: 42, limit: 120)
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "recall_window")
        XCTAssertEqual(json["session_id"] as? String, "session-1")
        XCTAssertEqual(json["center_ms"] as? Int, 42)
        XCTAssertEqual(json["limit"] as? Int, 120)
        XCTAssertNil(json["artifact_id"])
    }

    func testMomentDecodesCurrentRustShapeWithoutAudio() throws {
        let json = #"{"id":"m1","session_id":"s1","captured_at_ms":123,"image_artifact_id":"a1","is_favorite":false,"ocr_text":"hello","transcript_text":null}"#
        let moment = try JSONDecoder().decode(RecallMoment.self, from: Data(json.utf8))

        XCTAssertEqual(moment.id, "m1")
        XCTAssertEqual(moment.ocrText, "hello")
        XCTAssertNil(moment.audioArtifactId)
        XCTAssertNil(moment.audioStartedAtMs)
        XCTAssertNil(moment.accessibilityArtifactId)
        XCTAssertFalse(moment.hasVisibleTranscript)
    }

    func testVisibleTranscriptIgnoresBlankAudioOnlyMoments() throws {
        let blank = RecallMoment(
            id: "m1",
            sessionId: "s1",
            capturedAtMs: 1,
            imageArtifactId: "a1",
            transcriptText: "   ",
            audioArtifactId: "audio-1"
        )
        let spoken = RecallMoment(
            id: "m2",
            sessionId: "s1",
            capturedAtMs: 2,
            imageArtifactId: "a1",
            transcriptText: "hello there",
            audioArtifactId: "audio-2"
        )
        XCTAssertFalse(blank.hasVisibleTranscript)
        XCTAssertTrue(spoken.hasVisibleTranscript)
    }

    func testMomentDecodesAccessibilityArtifact() throws {
        let json = #"{"id":"m1","session_id":"s1","captured_at_ms":123,"image_artifact_id":"a1","is_favorite":false,"ocr_text":null,"transcript_text":null,"audio_artifact_id":null,"accessibility_artifact_id":"ax1","application_name":"Xcode","bundle_identifier":"com.apple.dt.Xcode"}"#
        let moment = try JSONDecoder().decode(RecallMoment.self, from: Data(json.utf8))
        XCTAssertEqual(moment.accessibilityArtifactId, "ax1")
        XCTAssertEqual(moment.applicationName, "Xcode")
        XCTAssertEqual(moment.bundleIdentifier, "com.apple.dt.Xcode")
    }

    func testArtifactMetaDecodesByteLengthWithoutPayload() throws {
        let json = #"{"id":"a1","content_type":"image/jpeg","byte_length":12}"#
        let meta = try JSONDecoder().decode(ArtifactMeta.self, from: Data(json.utf8))
        XCTAssertEqual(meta.id, "a1")
        XCTAssertEqual(meta.contentType, "image/jpeg")
        XCTAssertEqual(meta.byteLength, 12)
    }

    func testStatusDecodesRustShape() throws {
        let json = #"{"daemon_version":"0.1.0","protocol_version":1,"schema_version":1,"recording_state":"recording","active_session_id":"s1"}"#
        let status = try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.recordingState, .recording)
        XCTAssertEqual(status.activeSessionId, "s1")
    }

    func testSettingsRequestMatchesRustShape() throws {
        let data = try JSONEncoder().encode(WireRequest(type: "settings"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "settings")
        XCTAssertNil(json["record_audio"])
    }

    func testUpdateSettingsRequestMatchesRustShape() throws {
        let data = try JSONEncoder().encode(WireRequest(type: "update_settings", recordAudio: false))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "update_settings")
        XCTAssertEqual(json["record_audio"] as? Bool, false)
    }

    func testAppSettingsDecodesRustShape() throws {
        let json = #"{"data_dir":"/tmp/data","model_dir":"/tmp/models","record_audio":false,"capture_interval_seconds":10}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.dataDir, "/tmp/data")
        XCTAssertEqual(settings.modelDir, "/tmp/models")
        XCTAssertFalse(settings.recordAudio)
        XCTAssertEqual(settings.captureIntervalSeconds, 10)
    }

    func testModelLibraryDecodesInstalledPack() throws {
        let json = #"{"directory":"/tmp/models","packs":[{"id":"asr","name":"Qwen3 ASR","capability":"asr","path":"/tmp/models/Qwen3-ASR-1.7B","present":true,"bytes":1024,"required":true,"note":"qwen3"}]}"#
        let library = try JSONDecoder().decode(ModelLibrary.self, from: Data(json.utf8))
        XCTAssertEqual(library.directory, "/tmp/models")
        XCTAssertEqual(library.packs.first?.id, "asr")
        XCTAssertEqual(library.packs.first?.bytes, 1024)
        XCTAssertNil(library.packs.first?.expectedBytes)
        XCTAssertEqual(library.installedBytes, 1024)
    }

    func testModelLibraryDecodesDownloadProgress() throws {
        let json = #"{"directory":"/tmp/models","packs":[],"download":{"pack_id":"asr","bytes":42,"expected_bytes":100,"completed_files":0,"total_files":1}}"#
        let library = try JSONDecoder().decode(ModelLibrary.self, from: Data(json.utf8))
        XCTAssertEqual(library.download?.packId, "asr")
        XCTAssertEqual(library.download?.percent, 42)
        XCTAssertEqual(library.download?.fraction, 0.42)
    }

    func testModelPackDecodesExpectedBytes() throws {
        let json = #"{"id":"asr","name":"Qwen3 ASR","capability":"asr","path":"/tmp/qwen","present":false,"bytes":0,"required":true,"expected_bytes":2460000000}"#
        let pack = try JSONDecoder().decode(ModelPack.self, from: Data(json.utf8))
        XCTAssertEqual(pack.expectedBytes, 2_460_000_000)
    }

    func testDownloadModelsRequestMatchesRustShape() throws {
        let data = try JSONEncoder().encode(WireRequest(type: "download_models", packID: "asr"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "download_models")
        XCTAssertEqual(json["pack_id"] as? String, "asr")
    }

    func testShutdownRequestMatchesRustShape() throws {
        let data = try JSONEncoder().encode(WireRequest(type: "shutdown"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "shutdown")
    }

    func testShutdownResultDecodesDaemonPid() throws {
        let json = #"{"stopping":true,"pid":4321}"#
        let result = try JSONDecoder().decode(DaemonShutdownResult.self, from: Data(json.utf8))
        XCTAssertTrue(result.stopping)
        XCTAssertEqual(result.pid, 4321)
    }

    func testSearchRequestMatchesRustShape() throws {
        let request = WireRequest(type: "search", limit: 30, query: "design review")
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "search")
        XCTAssertEqual(json["query"] as? String, "design review")
        XCTAssertEqual(json["limit"] as? Int, 30)
    }

    func testRecordResultsDecodeBothDaemonBranches() throws {
        let started = #"{"session":{"id":"s1","started_at_ms":100,"ended_at_ms":null}}"#
        let existing = #"{"session_id":"s1","already_recording":true}"#
        let stopped = #"{"session_id":"s1"}"#

        XCTAssertEqual(
            try JSONDecoder().decode(RecordStartResult.self, from: Data(started.utf8)).effectiveSessionId,
            "s1"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RecordStartResult.self, from: Data(existing.utf8)).alreadyRecording,
            true
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RecordStopResult.self, from: Data(stopped.utf8)).sessionId,
            "s1"
        )
    }
}
