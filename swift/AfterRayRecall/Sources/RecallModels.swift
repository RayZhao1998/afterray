import Foundation

public struct RecallSession: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let startedAtMs: Int64
    public let endedAtMs: Int64?

    public init(id: String, startedAtMs: Int64, endedAtMs: Int64? = nil) {
        self.id = id
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
    }

    enum CodingKeys: String, CodingKey {
        case id
        case startedAtMs = "started_at_ms"
        case endedAtMs = "ended_at_ms"
    }
}

public struct RecallMoment: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionId: String
    public let capturedAtMs: Int64
    public let imageArtifactId: String
    public var isFavorite: Bool
    public let ocrText: String?
    public let transcriptText: String?

    /// Optional until the daemon's recall read model attaches the nearest audio segment.
    public let audioArtifactId: String?
    public let accessibilityArtifactId: String?

    public init(
        id: String,
        sessionId: String,
        capturedAtMs: Int64,
        imageArtifactId: String,
        isFavorite: Bool = false,
        ocrText: String? = nil,
        transcriptText: String? = nil,
        audioArtifactId: String? = nil,
        accessibilityArtifactId: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.capturedAtMs = capturedAtMs
        self.imageArtifactId = imageArtifactId
        self.isFavorite = isFavorite
        self.ocrText = ocrText
        self.transcriptText = transcriptText
        self.audioArtifactId = audioArtifactId
        self.accessibilityArtifactId = accessibilityArtifactId
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case capturedAtMs = "captured_at_ms"
        case imageArtifactId = "image_artifact_id"
        case isFavorite = "is_favorite"
        case ocrText = "ocr_text"
        case transcriptText = "transcript_text"
        case audioArtifactId = "audio_artifact_id"
        case accessibilityArtifactId = "accessibility_artifact_id"
    }
}

public struct ArtifactPayload: Codable, Equatable, Sendable {
    public let id: String
    public let contentType: String
    public let bytesBase64: String

    public var bytes: Data? { Data(base64Encoded: bytesBase64) }

    enum CodingKeys: String, CodingKey {
        case id
        case contentType = "content_type"
        case bytesBase64 = "bytes_base64"
    }
}

public enum DaemonRecordingState: String, Codable, Equatable, Sendable {
    case idle
    case recording
    case stopping
    case failed
}

public struct DaemonStatus: Codable, Equatable, Sendable {
    public let daemonVersion: String
    public let protocolVersion: Int
    public let schemaVersion: Int
    public let recordingState: DaemonRecordingState
    public let activeSessionId: String?

    public init(
        daemonVersion: String,
        protocolVersion: Int,
        schemaVersion: Int,
        recordingState: DaemonRecordingState,
        activeSessionId: String? = nil
    ) {
        self.daemonVersion = daemonVersion
        self.protocolVersion = protocolVersion
        self.schemaVersion = schemaVersion
        self.recordingState = recordingState
        self.activeSessionId = activeSessionId
    }

    enum CodingKeys: String, CodingKey {
        case daemonVersion = "daemon_version"
        case protocolVersion = "protocol_version"
        case schemaVersion = "schema_version"
        case recordingState = "recording_state"
        case activeSessionId = "active_session_id"
    }
}

public struct RecordStartResult: Codable, Equatable, Sendable {
    public let session: RecallSession?
    public let sessionId: String?
    public let alreadyRecording: Bool?

    public var effectiveSessionId: String? { session?.id ?? sessionId }

    public init(session: RecallSession? = nil, sessionId: String? = nil, alreadyRecording: Bool? = nil) {
        self.session = session
        self.sessionId = sessionId
        self.alreadyRecording = alreadyRecording
    }

    enum CodingKeys: String, CodingKey {
        case session
        case sessionId = "session_id"
        case alreadyRecording = "already_recording"
    }
}

public struct RecordStopResult: Codable, Equatable, Sendable {
    public let sessionId: String?
    public let alreadyStopped: Bool?

    public init(sessionId: String? = nil, alreadyStopped: Bool? = nil) {
        self.sessionId = sessionId
        self.alreadyStopped = alreadyStopped
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case alreadyStopped = "already_stopped"
    }
}

public struct RecallSearchHit: Codable, Equatable, Identifiable, Sendable {
    public let momentId: String
    public let sessionId: String
    public let capturedAtMs: Int64
    public let source: String
    public let text: String
    public let score: Double

    public var id: String { "\(momentId):\(source)" }

    public init(
        momentId: String,
        sessionId: String,
        capturedAtMs: Int64,
        source: String,
        text: String,
        score: Double
    ) {
        self.momentId = momentId
        self.sessionId = sessionId
        self.capturedAtMs = capturedAtMs
        self.source = source
        self.text = text
        self.score = score
    }

    enum CodingKeys: String, CodingKey {
        case momentId = "moment_id"
        case sessionId = "session_id"
        case capturedAtMs = "captured_at_ms"
        case source
        case text
        case score
    }
}

public enum RecallLoadState: Equatable, Sendable {
    case loading
    case ready
    case processing(message: String)
    case failed(message: String)
}

public struct RecallVisualTuning: Equatable, Sendable {
    public var thumbnailWidth: Double
    public var thumbnailSpacing: Double
    public var selectedScale: Double
    public var neighborScale: Double
    public var dimOpacity: Double
    public var glowStrength: Double
    public var dragPointsPerMoment: Double

    public init(
        thumbnailWidth: Double = 112,
        thumbnailSpacing: Double = 10,
        selectedScale: Double = 1.0,
        neighborScale: Double = 0.84,
        dimOpacity: Double = 0.30,
        glowStrength: Double = 0.62,
        dragPointsPerMoment: Double = 54
    ) {
        self.thumbnailWidth = thumbnailWidth
        self.thumbnailSpacing = thumbnailSpacing
        self.selectedScale = selectedScale
        self.neighborScale = neighborScale
        self.dimOpacity = dimOpacity
        self.glowStrength = glowStrength
        self.dragPointsPerMoment = dragPointsPerMoment
    }

    public static let standard = RecallVisualTuning()
}

public enum RecallGeometry {
    public static func clampedIndex(_ index: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(max(index, 0), count - 1)
    }

    public static func index(
        fromDragTranslation translation: Double,
        originIndex: Int,
        count: Int,
        pointsPerMoment: Double
    ) -> Int? {
        guard count > 0, pointsPerMoment > 0 else { return nil }
        let delta = Int((-translation / pointsPerMoment).rounded())
        return clampedIndex(originIndex + delta, count: count)
    }
}
