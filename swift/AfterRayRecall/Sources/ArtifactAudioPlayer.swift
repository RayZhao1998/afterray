import AVFoundation
import Foundation

@MainActor
public final class ArtifactAudioPlayer: NSObject, ObservableObject, RecallAudioPlaying, AVAudioPlayerDelegate {
    @Published public private(set) var isPlaying = false

    private let repository: RecallImageRepository
    private var player: AVAudioPlayer?
    private var playingArtifactID: String?

    public init(repository: RecallImageRepository) {
        self.repository = repository
    }

    public func toggle(moment: RecallMoment) async {
        guard let artifactID = moment.audioArtifactId else { return }
        if playingArtifactID == artifactID, let player {
            if player.isPlaying {
                player.pause()
            } else {
                player.play()
            }
            isPlaying = player.isPlaying
            return
        }
        do {
            let data = try await repository.data(artifactID: artifactID)
            let newPlayer = try AVAudioPlayer(data: data)
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            newPlayer.play()
            player = newPlayer
            playingArtifactID = artifactID
            isPlaying = true
        } catch {
            stop()
        }
    }

    public func stop() {
        player?.stop()
        player = nil
        playingArtifactID = nil
        isPlaying = false
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.stop() }
    }
}
