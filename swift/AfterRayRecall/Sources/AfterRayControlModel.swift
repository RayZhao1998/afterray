import Foundation

@MainActor
public final class AfterRayControlModel: ObservableObject {
    @Published public private(set) var status: DaemonStatus?
    @Published public private(set) var isChangingRecording = false
    @Published public var searchQuery = ""
    @Published public private(set) var searchHits: [RecallSearchHit] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var message: String?

    private let daemon: any AfterRayDaemonServing

    public init(daemon: any AfterRayDaemonServing) {
        self.daemon = daemon
    }

    public var isRecording: Bool { status?.recordingState == .recording }
    public var canToggleRecording: Bool {
        !isChangingRecording && status?.recordingState != .stopping
    }

    public func refreshStatus() async {
        do {
            status = try await daemon.status()
            message = nil
        } catch {
            status = nil
            message = error.localizedDescription
        }
    }

    @discardableResult
    public func toggleRecording() async -> Bool {
        guard canToggleRecording else { return false }
        isChangingRecording = true
        defer { isChangingRecording = false }
        do {
            if isRecording {
                _ = try await daemon.recordStop()
            } else {
                _ = try await daemon.recordStart()
            }
            status = try await daemon.status()
            message = nil
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    public func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchHits = []
            message = nil
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            searchHits = try await daemon.search(query: query, limit: 30)
            message = searchHits.isEmpty ? "No moments matched “\(query)”." : nil
        } catch {
            searchHits = []
            message = error.localizedDescription
        }
    }

    public func dismissSearch() {
        searchQuery = ""
        searchHits = []
        message = nil
    }
}
