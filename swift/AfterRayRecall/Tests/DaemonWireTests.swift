import Foundation
import XCTest
@testable import AfterRayRecall

final class DaemonWireTests: XCTestCase {
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
    }

    func testArtifactPayloadDecodesBytes() throws {
        let json = #"{"id":"a1","content_type":"image/png","bytes_base64":"aGVsbG8="}"#
        let payload = try JSONDecoder().decode(ArtifactPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.bytes, Data("hello".utf8))
    }

    func testStatusDecodesRustShape() throws {
        let json = #"{"daemon_version":"0.1.0","protocol_version":1,"schema_version":1,"recording_state":"recording","active_session_id":"s1"}"#
        let status = try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.recordingState, .recording)
        XCTAssertEqual(status.activeSessionId, "s1")
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
