import Foundation

@MainActor
public final class RecallStore: ObservableObject {
    @Published public private(set) var sessions: [RecallSession] = []
    @Published public private(set) var moments: [RecallMoment] = []
    @Published public var selectedIndex: Int = 0
    @Published public private(set) var loadState: RecallLoadState = .loading

    private let daemon: any RecallDaemonServing

    public init(daemon: any RecallDaemonServing) {
        self.daemon = daemon
    }

    public var selectedMoment: RecallMoment? {
        guard moments.indices.contains(selectedIndex) else { return nil }
        return moments[selectedIndex]
    }

    public func loadLatestSession() async {
        loadState = .loading
        do {
            sessions = try await daemon.sessions().sorted { $0.startedAtMs < $1.startedAtMs }
            guard let latest = sessions.last else {
                moments = []
                selectedIndex = 0
                loadState = .ready
                return
            }
            try await loadSession(id: latest.id)
        } catch {
            if Self.isDaemonConnectionError(error) {
                loadState = .loading
                return
            }
            moments = []
            selectedIndex = 0
            loadState = .failed(message: error.localizedDescription)
        }
    }

    public func loadSession(id: String, selecting momentID: String? = nil) async throws {
        let loaded = try await daemon.moments(sessionID: id).sorted { $0.capturedAtMs < $1.capturedAtMs }
        moments = loaded
        if let momentID, let index = loaded.firstIndex(where: { $0.id == momentID }) {
            selectedIndex = index
        } else {
            selectedIndex = max(loaded.count - 1, 0)
        }
        loadState = .ready
    }

    public func openSearchHit(_ hit: RecallSearchHit) async {
        loadState = .loading
        do {
            try await loadSession(id: hit.sessionId, selecting: hit.momentId)
        } catch {
            loadState = Self.isDaemonConnectionError(error)
                ? .loading
                : .failed(message: error.localizedDescription)
        }
    }

    public func select(index: Int) {
        guard let index = RecallGeometry.clampedIndex(index, count: moments.count) else { return }
        selectedIndex = index
    }

    public func toggleFavorite() async {
        guard moments.indices.contains(selectedIndex) else { return }
        let previous = moments[selectedIndex].isFavorite
        moments[selectedIndex].isFavorite.toggle()
        do {
            try await daemon.setFavorite(momentID: moments[selectedIndex].id, favorite: !previous)
        } catch {
            moments[selectedIndex].isFavorite = previous
            loadState = Self.isDaemonConnectionError(error)
                ? .loading
                : .failed(message: error.localizedDescription)
        }
    }

    private static func isDaemonConnectionError(_ error: Error) -> Bool {
        guard let daemonError = error as? DaemonClientError else { return false }
        if case .connection = daemonError { return true }
        return false
    }
}

public actor RecallImageRepository {
    private let daemon: any RecallDaemonServing
    private var cache: [String: Data] = [:]

    public init(daemon: any RecallDaemonServing) {
        self.daemon = daemon
    }

    public func data(artifactID: String) async throws -> Data {
        if let cached = cache[artifactID] { return cached }
        let payload = try await daemon.artifact(id: artifactID)
        guard let bytes = payload.bytes else { throw DaemonClientError.invalidResponse }
        cache[artifactID] = bytes
        return bytes
    }

    public func prefetch(artifactIDs: [String]) async {
        for id in artifactIDs where cache[id] == nil {
            _ = try? await data(artifactID: id)
        }
    }
}

@MainActor
public protocol RecallAudioPlaying: AnyObject {
    var isPlaying: Bool { get }
    func toggle(moment: RecallMoment) async
    func stop()
}
