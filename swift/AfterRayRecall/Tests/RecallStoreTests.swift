import XCTest
@testable import AfterRayRecall

@MainActor
final class RecallStoreTests: XCTestCase {
    func testLoadSelectsLatestMomentAndFavoritePersistsThroughDaemon() async {
        let daemon = FakeDaemon()
        let store = RecallStore(daemon: daemon)

        await store.loadLatestSession()
        XCTAssertEqual(store.selectedMoment?.id, "m2")

        await store.toggleFavorite()
        XCTAssertEqual(store.selectedMoment?.isFavorite, true)
        let calls = await daemon.favoriteCalls
        XCTAssertEqual(calls, [.init(momentID: "m2", favorite: true)])
    }

    func testConnectionFailureStaysInRecoveringState() async {
        let store = RecallStore(daemon: ConnectionFailingDaemon())

        await store.loadLatestSession()

        XCTAssertEqual(store.loadState, .loading)
    }
}

private actor ConnectionFailingDaemon: RecallDaemonServing {
    func sessions() async throws -> [RecallSession] {
        throw DaemonClientError.connection("Connection refused")
    }

    func moments(sessionID _: String) async throws -> [RecallMoment] { [] }
    func recallWindow(sessionID _: String, centerMs _: Int64, limit _: Int) async throws -> [RecallMoment] { [] }
    func artifact(id _: String) async throws -> ArtifactPayload {
        throw DaemonClientError.connection("Connection refused")
    }
    func setFavorite(momentID _: String, favorite _: Bool) async throws {}
}

private actor FakeDaemon: RecallDaemonServing {
    struct FavoriteCall: Equatable { let momentID: String; let favorite: Bool }
    var favoriteCalls: [FavoriteCall] = []

    func sessions() async throws -> [RecallSession] {
        [RecallSession(id: "s1", startedAtMs: 100)]
    }

    func moments(sessionID: String) async throws -> [RecallMoment] {
        [
            RecallMoment(id: "m1", sessionId: sessionID, capturedAtMs: 100, imageArtifactId: "a1"),
            RecallMoment(id: "m2", sessionId: sessionID, capturedAtMs: 200, imageArtifactId: "a2"),
        ]
    }

    func recallWindow(sessionID: String, centerMs: Int64, limit: Int) async throws -> [RecallMoment] {
        try await moments(sessionID: sessionID)
    }

    func artifact(id: String) async throws -> ArtifactPayload {
        ArtifactPayload(id: id, contentType: "image/png", bytesBase64: "")
    }

    func setFavorite(momentID: String, favorite: Bool) async throws {
        favoriteCalls.append(.init(momentID: momentID, favorite: favorite))
    }
}
