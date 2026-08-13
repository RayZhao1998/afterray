import XCTest
@testable import AfterRayRecall

final class ArtifactAudioPlaybackSessionTests: XCTestCase {
    func testCompletedLoadAfterStopDoesNotEnterPlaying() {
        var session = ArtifactAudioPlaybackSession()
        let generation = session.beginPlay(artifactID: "audio-1")

        XCTAssertTrue(session.isBuffering)
        XCTAssertEqual(session.artifactID, "audio-1")
        XCTAssertFalse(session.isPlaying)

        session.stop()

        XCTAssertFalse(session.isBuffering)
        XCTAssertFalse(session.isPlaying)
        XCTAssertNil(session.artifactID)
        XCTAssertNotEqual(session.generation, generation)
        XCTAssertFalse(session.finishLoad(generation: generation))
        XCTAssertFalse(session.isPlaying)
        XCTAssertFalse(session.isBuffering)
    }

    func testToggleWhileBufferingCancelsAndIgnoresLateLoad() {
        var session = ArtifactAudioPlaybackSession()
        let generation = session.beginPlay(artifactID: "audio-1")

        XCTAssertTrue(session.cancelIfBuffering(artifactID: "audio-1"))
        XCTAssertFalse(session.isBuffering)
        XCTAssertFalse(session.isPlaying)
        XCTAssertNil(session.artifactID)
        XCTAssertFalse(session.finishLoad(generation: generation))
        XCTAssertFalse(session.isPlaying)
    }

    func testCancelIfBufferingIgnoresADifferentArtifact() {
        var session = ArtifactAudioPlaybackSession()
        let generation = session.beginPlay(artifactID: "audio-1")

        XCTAssertFalse(session.cancelIfBuffering(artifactID: "audio-2"))
        XCTAssertTrue(session.isBuffering)
        XCTAssertEqual(session.artifactID, "audio-1")
        XCTAssertTrue(session.finishLoad(generation: generation))
        XCTAssertTrue(session.isPlaying)
    }

    func testFailLoadAfterCancelIsIgnored() {
        var session = ArtifactAudioPlaybackSession()
        let generation = session.beginPlay(artifactID: "audio-1")
        session.stop()
        session.failLoad(generation: generation)
        XCTAssertFalse(session.isPlaying)
        XCTAssertFalse(session.isBuffering)
        XCTAssertNil(session.artifactID)
    }
}

@MainActor
final class ArtifactAudioPlayerTests: XCTestCase {
    func testOffsetUsesAudioStartedAtMsAndClampsBelowZero() {
        XCTAssertEqual(
            ArtifactAudioPlayer.offset(for: moment(capturedAtMs: 2_500, startedAtMs: 1_000)),
            1.5,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            ArtifactAudioPlayer.offset(for: moment(capturedAtMs: 500, startedAtMs: 1_000)),
            0,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            ArtifactAudioPlayer.offset(for: moment(capturedAtMs: 2_500, startedAtMs: nil)),
            0,
            accuracy: 0.000_1
        )
    }

    func testStopDuringLoadDoesNotStartPlayback() async throws {
        let daemon = DelayedArtifactDaemon(delayMs: 80)
        let player = ArtifactAudioPlayer(repository: RecallImageRepository(daemon: daemon))
        let target = moment(capturedAtMs: 2_500, startedAtMs: 1_000, audioID: "audio-1")

        player.play(moment: target)
        XCTAssertTrue(player.isBuffering)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.playingArtifactID, "audio-1")
        let generation = player.generation

        player.stop()
        XCTAssertFalse(player.isBuffering)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.playingArtifactID)
        XCTAssertNotEqual(player.generation, generation)

        try await Task.sleep(for: .milliseconds(140))
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isBuffering)
        XCTAssertNil(player.playingArtifactID)
    }

    func testToggleWhileLoadingCancelsAndDoesNotPlay() async throws {
        let daemon = DelayedArtifactDaemon(delayMs: 80)
        let player = ArtifactAudioPlayer(repository: RecallImageRepository(daemon: daemon))
        let target = moment(capturedAtMs: 2_500, startedAtMs: 1_000, audioID: "audio-1")

        player.toggle(moment: target)
        XCTAssertTrue(player.isBuffering)
        XCTAssertEqual(player.playingArtifactID, "audio-1")
        let generation = player.generation

        player.toggle(moment: target)
        XCTAssertFalse(player.isBuffering)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.playingArtifactID)
        XCTAssertNotEqual(player.generation, generation)

        try await Task.sleep(for: .milliseconds(140))
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isBuffering)
        XCTAssertNil(player.playingArtifactID)
    }

    private func moment(
        capturedAtMs: Int64,
        startedAtMs: Int64?,
        audioID: String = "audio-1"
    ) -> RecallMoment {
        RecallMoment(
            id: "m1",
            sessionId: "s1",
            capturedAtMs: capturedAtMs,
            imageArtifactId: "img-1",
            audioArtifactId: audioID,
            audioStartedAtMs: startedAtMs
        )
    }
}

private actor DelayedArtifactDaemon: RecallDaemonServing {
    private let delayMs: Int

    init(delayMs: Int) {
        self.delayMs = delayMs
    }

    func sessions() async throws -> [RecallSession] { [] }
    func timeline() async throws -> [RecallMoment] { [] }
    func timeline(sinceMs _: Int64) async throws -> [RecallMoment] { [] }
    func moments(sessionID _: String) async throws -> [RecallMoment] { [] }
    func recallWindow(sessionID _: String, centerMs _: Int64, limit _: Int) async throws -> [RecallMoment] { [] }
    func setFavorite(momentID _: String, favorite _: Bool) async throws {}

    func artifact(id: String) async throws -> ArtifactPayload {
        try await Task.sleep(for: .milliseconds(delayMs))
        return ArtifactPayload(id: id, contentType: "audio/m4a", bytes: Data("audio".utf8))
    }
}
