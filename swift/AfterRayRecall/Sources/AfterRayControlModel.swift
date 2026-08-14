import Foundation

@MainActor
public final class AfterRayControlModel: ObservableObject {
    @Published public private(set) var status: DaemonStatus?
    @Published public private(set) var isChangingRecording = false
    @Published public var searchQuery = ""
    @Published public private(set) var searchHits: [RecallSearchHit] = []
    @Published public private(set) var isSearching = false
    @Published public var askQuestion = ""
    @Published public private(set) var askAnswer: AskAnswer?
    @Published public private(set) var isAsking = false
    @Published public private(set) var askMessage: String?
    @Published public private(set) var message: String?

    private let daemon: any AfterRayDaemonServing
    private var sensitiveGeneration: UInt64 = 0

    public init(daemon: any AfterRayDaemonServing) {
        self.daemon = daemon
    }

    public var isRecording: Bool { status?.recordingState == .recording }
    public var isWaitingToRecord: Bool { status?.recordingState == .waiting }
    public var isCaptureSessionActive: Bool {
        switch status?.recordingState {
        case .waiting, .recording, .stopping: return true
        default: return false
        }
    }
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

    /// Starts capture when the daemon is idle. Calling this repeatedly is safe.
    @discardableResult
    public func ensureRecording() async -> Bool {
        await refreshStatus()
        guard status?.recordingState == .idle || status == nil else {
            return isCaptureSessionActive
        }
        AfterRayLog.info("ensureRecording: starting capture")
        isChangingRecording = true
        markWaitingOptimistically()
        defer { isChangingRecording = false }
        do {
            _ = try await daemon.recordStart()
            status = try await daemon.status()
            message = nil
            AfterRayLog.info(
                "ensureRecording: state=\(status?.recordingState.rawValue ?? "nil")"
            )
            return isCaptureSessionActive
        } catch {
            AfterRayLog.error("ensureRecording: \(error.localizedDescription)")
            message = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func toggleRecording() async -> Bool {
        guard canToggleRecording else { return false }
        isChangingRecording = true
        defer { isChangingRecording = false }
        do {
            if isCaptureSessionActive {
                _ = try await daemon.recordStop(reason: "pause")
            } else {
                markWaitingOptimistically()
                _ = try await daemon.recordStart()
            }
            status = try await daemon.status()
            message = nil
            return true
        } catch {
            AfterRayLog.error("toggleRecording: \(error.localizedDescription)")
            message = error.localizedDescription
            return false
        }
    }

    public func search() async {
        let requestGeneration = sensitiveGeneration
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchHits = []
            message = nil
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let hits = try await daemon.search(query: query, limit: 30)
            guard sensitiveGeneration == requestGeneration else { return }
            searchHits = hits
            message = searchHits.isEmpty ? "No moments matched “\(query)”." : nil
        } catch {
            guard sensitiveGeneration == requestGeneration else { return }
            searchHits = []
            message = error.localizedDescription
        }
    }

    public func dismissSearch() {
        searchQuery = ""
        searchHits = []
        message = nil
    }

    public func ask() async {
        let requestGeneration = sensitiveGeneration
        let question = askQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            askAnswer = nil
            askMessage = nil
            return
        }
        isAsking = true
        defer { isAsking = false }
        do {
            let answer = try await daemon.ask(question: question, fromMs: nil, toMs: nil)
            guard sensitiveGeneration == requestGeneration else { return }
            askAnswer = answer
            askMessage = nil
        } catch {
            guard sensitiveGeneration == requestGeneration else { return }
            askAnswer = nil
            askMessage = error.localizedDescription
        }
    }

    public func dismissAsk() {
        askQuestion = ""
        askAnswer = nil
        askMessage = nil
    }

    public func clearSensitiveState() {
        sensitiveGeneration &+= 1
        status = nil
        searchQuery = ""
        searchHits = []
        isSearching = false
        askQuestion = ""
        askAnswer = nil
        isAsking = false
        askMessage = nil
        message = nil
    }

    private func markWaitingOptimistically() {
        if let status {
            self.status = DaemonStatus(
                daemonVersion: status.daemonVersion,
                protocolVersion: status.protocolVersion,
                schemaVersion: status.schemaVersion,
                recordingState: .waiting,
                activeSessionId: status.activeSessionId
            )
        }
    }
}
