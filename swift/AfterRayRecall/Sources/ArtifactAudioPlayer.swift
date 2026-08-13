import AVFoundation
import Foundation

/// Generation-guarded playback session. A completed fetch may only start
/// audio when `finishLoad` accepts the same generation that `beginPlay` issued.
struct ArtifactAudioPlaybackSession: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case buffering
        case playing
        case paused
    }

    private(set) var phase: Phase = .idle
    private(set) var artifactID: String?
    private(set) var generation: UInt64 = 0

    var isPlaying: Bool { phase == .playing }
    var isBuffering: Bool { phase == .buffering }

    @discardableResult
    mutating func beginPlay(artifactID: String) -> UInt64 {
        generation &+= 1
        self.artifactID = artifactID
        phase = .buffering
        return generation
    }

    /// Returns true only if this load is still the active request.
    mutating func finishLoad(generation request: UInt64) -> Bool {
        guard generation == request, phase == .buffering else { return false }
        phase = .playing
        return true
    }

    mutating func failLoad(generation request: UInt64) {
        guard generation == request, phase == .buffering else { return }
        resetKeepingGeneration()
    }

    mutating func pause() {
        guard phase == .playing else { return }
        phase = .paused
    }

    mutating func resume() {
        guard phase == .paused else { return }
        phase = .playing
    }

    mutating func stop() {
        generation &+= 1
        resetKeepingGeneration()
    }

    @discardableResult
    mutating func cancelIfBuffering(artifactID: String) -> Bool {
        guard phase == .buffering, self.artifactID == artifactID else { return false }
        stop()
        return true
    }

    private mutating func resetKeepingGeneration() {
        phase = .idle
        artifactID = nil
    }
}

@MainActor
public final class ArtifactAudioPlayer: NSObject, ObservableObject, RecallAudioPlaying, AVAudioPlayerDelegate {
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isBuffering = false
    @Published public private(set) var playingArtifactID: String?

    public var generation: UInt64 { session.generation }

    private let repository: RecallImageRepository
    private var session = ArtifactAudioPlaybackSession()
    private var player: AVAudioPlayer?
    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchArtifactID: String?

    public init(repository: RecallImageRepository) {
        self.repository = repository
    }

    public func toggle(moment: RecallMoment) {
        guard let artifactID = moment.audioArtifactId else { return }
        if session.cancelIfBuffering(artifactID: artifactID) {
            loadTask?.cancel()
            loadTask = nil
            abandonEngine()
            publish()
            return
        }
        if session.artifactID == artifactID, let player, session.phase == .playing || session.phase == .paused {
            let offset = Self.offset(for: moment)
            if session.isPlaying, abs(player.currentTime - offset) < 1.5 {
                pause()
                return
            }
            seek(player, to: offset)
            player.play()
            session.resume()
            publish()
            return
        }
        play(moment: moment)
    }

    public func play(moment: RecallMoment) {
        guard let artifactID = moment.audioArtifactId else { return }
        let offset = Self.offset(for: moment)

        if session.artifactID == artifactID, let player, !session.isBuffering {
            seek(player, to: offset)
            player.play()
            session.resume()
            publish()
            return
        }

        player?.stop()
        player = nil

        let request = session.beginPlay(artifactID: artifactID)
        publish()

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.loadAndStart(artifactID: artifactID, offset: offset, generation: request)
        }
    }

    public func pause() {
        player?.pause()
        session.pause()
        publish()
    }

    public func stop() {
        session.stop()
        loadTask?.cancel()
        loadTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchArtifactID = nil
        abandonEngine()
        publish()
    }

    public func prefetch(artifactID: String?) {
        guard let artifactID else {
            prefetchTask?.cancel()
            prefetchTask = nil
            prefetchArtifactID = nil
            return
        }
        guard prefetchArtifactID != artifactID else { return }
        prefetchTask?.cancel()
        prefetchArtifactID = artifactID
        prefetchTask = Task { [repository] in
            _ = try? await repository.data(artifactID: artifactID)
        }
    }

    public static func offset(for moment: RecallMoment) -> TimeInterval {
        guard let startedAtMs = moment.audioStartedAtMs else { return 0 }
        return max(Double(moment.capturedAtMs - startedAtMs) / 1_000, 0)
    }

    private func loadAndStart(artifactID: String, offset: TimeInterval, generation request: UInt64) async {
        do {
            let data = try await repository.data(artifactID: artifactID)
            guard session.generation == request, session.phase == .buffering else { return }
            let newPlayer = try AVAudioPlayer(data: data)
            guard session.finishLoad(generation: request) else {
                newPlayer.stop()
                return
            }
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            seek(newPlayer, to: offset)
            newPlayer.play()
            player = newPlayer
            publish()
        } catch {
            guard session.generation == request else { return }
            session.failLoad(generation: request)
            abandonEngine()
            publish()
        }
    }

    private func seek(_ player: AVAudioPlayer, to offset: TimeInterval) {
        player.currentTime = min(offset, max(player.duration - 0.05, 0))
    }

    private func abandonEngine() {
        player?.stop()
        player = nil
    }

    private func publish() {
        isPlaying = session.isPlaying
        isBuffering = session.isBuffering
        playingArtifactID = session.artifactID
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === finished else { return }
            self.stop()
        }
    }
}
