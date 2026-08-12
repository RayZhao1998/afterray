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

    public func loadLatestSession(preservingSelection: Bool = false) async {
        if moments.isEmpty {
            loadState = .loading
        }
        do {
            sessions = try await daemon.sessions().sorted { $0.startedAtMs < $1.startedAtMs }
            guard let latest = sessions.last else {
                moments = []
                selectedIndex = 0
                loadState = .ready
                return
            }
            let sessionID = preservingSelection ? selectedMoment?.sessionId ?? latest.id : latest.id
            try await loadSession(id: sessionID, preservingSelection: preservingSelection)
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

    public func loadSession(
        id: String,
        selecting momentID: String? = nil,
        preservingSelection: Bool = false
    ) async throws {
        let loaded = try await daemon.moments(sessionID: id).sorted { $0.capturedAtMs < $1.capturedAtMs }
        // Read the selection after the daemon request returns. The user may
        // continue scrubbing while that request is in flight, and the refresh
        // must preserve their newest position rather than a stale snapshot.
        let preservedMomentID = preservingSelection ? selectedMoment?.id : nil
        let preservedIndex = selectedIndex
        moments = loaded
        if let targetID = momentID ?? preservedMomentID,
           let index = loaded.firstIndex(where: { $0.id == targetID })
        {
            selectedIndex = index
        } else if preservingSelection {
            selectedIndex = min(max(preservedIndex, 0), max(loaded.count - 1, 0))
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
    private let cache = NSCache<NSString, NSData>()
    private var inFlight: [String: Task<Data, Error>] = [:]

    public init(daemon: any RecallDaemonServing) {
        self.daemon = daemon
        cache.countLimit = 128
        cache.totalCostLimit = 512 * 1_024 * 1_024
    }

    public func data(artifactID: String) async throws -> Data {
        if let cached = cache.object(forKey: artifactID as NSString) { return cached as Data }
        if let existing = inFlight[artifactID] { return try await existing.value }
        let daemon = daemon
        let task = Task<Data, Error> {
            let payload = try await daemon.artifact(id: artifactID)
            guard let bytes = payload.bytes else { throw DaemonClientError.invalidResponse }
            return bytes
        }
        inFlight[artifactID] = task
        do {
            let bytes = try await task.value
            inFlight[artifactID] = nil
            cache.setObject(bytes as NSData, forKey: artifactID as NSString, cost: bytes.count)
            return bytes
        } catch {
            inFlight[artifactID] = nil
            throw error
        }
    }

    public func prefetch(artifactIDs: [String]) async {
        for id in artifactIDs where cache.object(forKey: id as NSString) == nil {
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
