import Darwin
import Foundation

public enum DaemonClientError: LocalizedError, Equatable {
    case connection(String)
    case invalidResponse
    case rejected(String)
    case protocolMismatch(Int)
    case missingData

    public var errorDescription: String? {
        switch self {
        case .connection(let message): "Could not reach afterrayd: \(message)"
        case .invalidResponse: "afterrayd returned invalid JSON"
        case .rejected(let message): message
        case .protocolMismatch(let version): "Unsupported daemon protocol \(version)"
        case .missingData: "afterrayd returned no data"
        }
    }
}

public protocol RecallDaemonServing: Sendable {
    func sessions() async throws -> [RecallSession]
    func timeline() async throws -> [RecallMoment]
    func moments(sessionID: String) async throws -> [RecallMoment]
    func recallWindow(sessionID: String, centerMs: Int64, limit: Int) async throws -> [RecallMoment]
    func artifact(id: String) async throws -> ArtifactPayload
    func setFavorite(momentID: String, favorite: Bool) async throws
}

public protocol AfterRayDaemonServing: RecallDaemonServing {
    func status() async throws -> DaemonStatus
    func recordStart() async throws -> RecordStartResult
    func recordStop() async throws -> RecordStopResult
    func search(query: String, limit: Int) async throws -> [RecallSearchHit]
}

public actor UnixSocketDaemonClient: AfterRayDaemonServing {
    public static let protocolVersion = 1
    public let socketPath: String

    public init(socketPath: String? = nil) {
        self.socketPath = socketPath
            ?? ProcessInfo.processInfo.environment["AFTERRAY_SOCKET"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("afterray-v0.sock")
    }

    public func sessions() async throws -> [RecallSession] {
        try await request(WireRequest(type: "sessions_list"), as: [RecallSession].self)
    }

    public func timeline() async throws -> [RecallMoment] {
        try await request(WireRequest(type: "timeline_list"), as: [RecallMoment].self)
    }

    public func status() async throws -> DaemonStatus {
        try await request(WireRequest(type: "status"), as: DaemonStatus.self)
    }

    public func recordStart() async throws -> RecordStartResult {
        try await request(WireRequest(type: "record_start"), as: RecordStartResult.self)
    }

    public func recordStop() async throws -> RecordStopResult {
        try await request(WireRequest(type: "record_stop"), as: RecordStopResult.self)
    }

    public func search(query: String, limit: Int = 30) async throws -> [RecallSearchHit] {
        try await request(
            WireRequest(type: "search", limit: limit, query: query),
            as: [RecallSearchHit].self
        )
    }

    public func moments(sessionID: String) async throws -> [RecallMoment] {
        try await request(WireRequest(type: "moments_list", sessionID: sessionID), as: [RecallMoment].self)
    }

    public func recallWindow(sessionID: String, centerMs: Int64, limit: Int = 120) async throws -> [RecallMoment] {
        try await request(
            WireRequest(type: "recall_window", sessionID: sessionID, centerMs: centerMs, limit: limit),
            as: [RecallMoment].self
        )
    }

    public func artifact(id: String) async throws -> ArtifactPayload {
        try await request(WireRequest(type: "read_artifact", artifactID: id), as: ArtifactPayload.self)
    }

    public func setFavorite(momentID: String, favorite: Bool) async throws {
        let _: EmptyResponse = try await request(
            WireRequest(type: "favorite_set", momentID: momentID, favorite: favorite),
            as: EmptyResponse.self,
            allowEmptyObject: true
        )
    }

    private func request<T: Decodable>(
        _ request: WireRequest,
        as type: T.Type,
        allowEmptyObject: Bool = false
    ) async throws -> T {
        let encoder = JSONEncoder()
        var payload = try encoder.encode(request)
        payload.append(0x0A)
        let path = socketPath
        let responseData = try await Task.detached(priority: .userInitiated) {
            try UnixLineTransport.exchange(path: path, payload: payload)
        }.value

        guard
            let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let version = object["protocol_version"] as? Int,
            let ok = object["ok"] as? Bool
        else { throw DaemonClientError.invalidResponse }

        guard version == Self.protocolVersion else {
            throw DaemonClientError.protocolMismatch(version)
        }
        guard ok else {
            throw DaemonClientError.rejected(object["error"] as? String ?? "Unknown daemon error")
        }

        if let dataObject = object["data"] {
            let nested = try JSONSerialization.data(withJSONObject: dataObject)
            return try JSONDecoder().decode(T.self, from: nested)
        }
        if allowEmptyObject, let empty = EmptyResponse() as? T { return empty }
        throw DaemonClientError.missingData
    }
}

struct WireRequest: Encodable, Equatable {
    let type: String
    var sessionID: String?
    var centerMs: Int64?
    var limit: Int?
    var artifactID: String?
    var momentID: String?
    var favorite: Bool?
    var query: String?

    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "session_id"
        case centerMs = "center_ms"
        case limit
        case artifactID = "artifact_id"
        case momentID = "moment_id"
        case favorite
        case query
    }
}

private struct EmptyResponse: Codable {
    init() {}
}

private enum UnixLineTransport {
    static func exchange(path: String, payload: Data) throws -> Data {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError("open socket") }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            throw DaemonClientError.connection("socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw posixError("connect") }

        try payload.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), rawBuffer.count - written)
                guard count > 0 else { throw posixError("write") }
                written += count
            }
        }

        let maximumResponseBytes = 64 * 1_024 * 1_024
        var response = Data()
        response.reserveCapacity(256 * 1_024)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while response.count < maximumResponseBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            let bytes = buffer[..<count]
            if let newline = bytes.firstIndex(of: 0x0A) {
                response.append(contentsOf: bytes[..<newline])
                break
            }
            response.append(contentsOf: bytes)
        }
        guard !response.isEmpty else { throw DaemonClientError.connection("empty response") }
        return response
    }

    private static func posixError(_ operation: String) -> DaemonClientError {
        DaemonClientError.connection("\(operation): \(String(cString: strerror(errno)))")
    }
}
