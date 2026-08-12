import Foundation

@MainActor
public final class RecallStore: ObservableObject {
    @Published public private(set) var sessions: [RecallSession] = []
    @Published public private(set) var moments: [RecallMoment] = []
    @Published public var selectedIndex: Int = 0
    @Published public private(set) var loadState: RecallLoadState = .loading

    private let daemon: any RecallDaemonServing
    private var sensitiveGeneration: UInt64 = 0

    public init(daemon: any RecallDaemonServing) {
        self.daemon = daemon
    }

    public var selectedMoment: RecallMoment? {
        guard moments.indices.contains(selectedIndex) else { return nil }
        return moments[selectedIndex]
    }

    public func loadTimeline(preservingSelection: Bool = false) async {
        let requestGeneration = sensitiveGeneration
        if moments.isEmpty {
            loadState = .loading
        }
        do {
            let loadedSessions = try await daemon.sessions().sorted { $0.startedAtMs < $1.startedAtMs }
            let loaded = try await daemon.timeline().sorted { $0.capturedAtMs < $1.capturedAtMs }
            guard sensitiveGeneration == requestGeneration else { return }
            sessions = loadedSessions
            apply(loaded, preservingSelection: preservingSelection)
        } catch {
            guard sensitiveGeneration == requestGeneration else { return }
            if Self.isDaemonConnectionError(error) {
                loadState = .loading
                return
            }
            moments = []
            selectedIndex = 0
            loadState = .failed(message: error.localizedDescription)
        }
    }

    /// Refreshes a small overlap window so recently completed OCR/AX work can
    /// replace existing moments without rescanning the entire encrypted vault.
    public func refreshTimeline(preservingSelection: Bool = true) async {
        guard !moments.isEmpty else {
            await loadTimeline(preservingSelection: preservingSelection)
            return
        }

        let overlapStart = max(moments.count - 20, 0)
        let sinceMs = moments[overlapStart].capturedAtMs
        let requestGeneration = sensitiveGeneration
        do {
            let updated = try await daemon.timeline(sinceMs: sinceMs)
                .sorted { left, right in
                    if left.capturedAtMs == right.capturedAtMs { return left.id < right.id }
                    return left.capturedAtMs < right.capturedAtMs
                }
            guard sensitiveGeneration == requestGeneration else { return }
            guard !updated.isEmpty else { return }
            let prefix = moments.prefix { $0.capturedAtMs < sinceMs }
            let existingOverlap = Array(moments.dropFirst(prefix.count))
            guard existingOverlap != updated else { return }
            apply(Array(prefix) + updated, preservingSelection: preservingSelection)
        } catch {
            guard sensitiveGeneration == requestGeneration else { return }
            if !Self.isDaemonConnectionError(error) {
                loadState = .failed(message: error.localizedDescription)
            }
        }
    }

    public func loadSession(
        id: String,
        selecting momentID: String? = nil,
        preservingSelection: Bool = false
    ) async throws {
        let requestGeneration = sensitiveGeneration
        let loaded = try await daemon.moments(sessionID: id).sorted { $0.capturedAtMs < $1.capturedAtMs }
        guard sensitiveGeneration == requestGeneration else { return }
        apply(loaded, selecting: momentID, preservingSelection: preservingSelection)
    }

    private func apply(
        _ loaded: [RecallMoment],
        selecting momentID: String? = nil,
        preservingSelection: Bool = false
    ) {
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
        let requestGeneration = sensitiveGeneration
        loadState = .loading
        do {
            let loaded = try await daemon.timeline().sorted { $0.capturedAtMs < $1.capturedAtMs }
            guard sensitiveGeneration == requestGeneration else { return }
            apply(loaded, selecting: hit.momentId)
        } catch {
            guard sensitiveGeneration == requestGeneration else { return }
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
        let momentID = moments[selectedIndex].id
        let previous = moments[selectedIndex].isFavorite
        moments[selectedIndex].isFavorite.toggle()
        do {
            try await daemon.setFavorite(momentID: momentID, favorite: !previous)
        } catch {
            guard let index = moments.firstIndex(where: { $0.id == momentID }) else { return }
            moments[index].isFavorite = previous
            loadState = Self.isDaemonConnectionError(error)
                ? .loading
                : .failed(message: error.localizedDescription)
        }
    }

    public func clearSensitiveState() {
        sensitiveGeneration &+= 1
        sessions = []
        moments = []
        selectedIndex = 0
        loadState = .loading
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
    private var cachedArtifactIDs: Set<String> = []
    private var generation: UInt64 = 0

    public init(daemon: any RecallDaemonServing) {
        self.daemon = daemon
        cache.countLimit = 128
        cache.totalCostLimit = 512 * 1_024 * 1_024
    }

    public func data(artifactID: String) async throws -> Data {
        if let cached = cache.object(forKey: artifactID as NSString) { return cached as Data }
        if let existing = inFlight[artifactID] { return try await existing.value }
        let daemon = daemon
        let requestGeneration = generation
        let task = Task<Data, Error> {
            try await daemon.artifact(id: artifactID).bytes
        }
        inFlight[artifactID] = task
        do {
            let bytes = try await task.value
            inFlight[artifactID] = nil
            guard generation == requestGeneration else { return bytes }
            cache.setObject(
                NSMutableData(data: bytes),
                forKey: artifactID as NSString,
                cost: bytes.count
            )
            cachedArtifactIDs.insert(artifactID)
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

    public func clearSensitiveData() {
        generation &+= 1
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        for artifactID in cachedArtifactIDs {
            guard let data = cache.object(forKey: artifactID as NSString) as? NSMutableData else {
                continue
            }
            data.resetBytes(in: NSRange(location: 0, length: data.length))
        }
        cachedArtifactIDs.removeAll()
        cache.removeAllObjects()
    }
}

@MainActor
public protocol RecallAudioPlaying: AnyObject {
    var isPlaying: Bool { get }
    func toggle(moment: RecallMoment) async
    func stop()
}
