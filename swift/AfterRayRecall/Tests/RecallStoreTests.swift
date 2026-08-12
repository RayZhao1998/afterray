import XCTest
@testable import AfterRayRecall

@MainActor
final class RecallStoreTests: XCTestCase {
    func testLoadSelectsLatestMomentAndFavoritePersistsThroughDaemon() async {
        let daemon = FakeDaemon()
        let store = RecallStore(daemon: daemon)

        await store.loadTimeline()
        XCTAssertEqual(store.sessions.map(\.id), ["s1", "s2"])
        XCTAssertEqual(store.moments.map(\.id), ["m1", "m2"])
        XCTAssertEqual(store.selectedMoment?.id, "m2")

        await store.toggleFavorite()
        XCTAssertEqual(store.selectedMoment?.isFavorite, true)
        let calls = await daemon.favoriteCalls
        XCTAssertEqual(calls, [.init(momentID: "m2", favorite: true)])
    }

    func testConnectionFailureStaysInRecoveringState() async {
        let store = RecallStore(daemon: ConnectionFailingDaemon())

        await store.loadTimeline()

        XCTAssertEqual(store.loadState, .loading)
    }

    func testImageRepositoryCoalescesConcurrentArtifactLoads() async throws {
        let daemon = CountingArtifactDaemon()
        let repository = RecallImageRepository(daemon: daemon)

        async let first = repository.data(artifactID: "frame-1")
        async let second = repository.data(artifactID: "frame-1")
        let (firstData, secondData) = try await (first, second)

        XCTAssertEqual(firstData, Data("frame".utf8))
        XCTAssertEqual(secondData, firstData)
        let requestCount = await daemon.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testBackgroundRefreshPreservesLatestUserSelection() async {
        let daemon = RefreshingDaemon()
        let store = RecallStore(daemon: daemon)
        await store.loadTimeline()
        XCTAssertEqual(store.selectedMoment?.id, "m2")

        store.select(index: 0)
        await daemon.appendMoment(id: "m3", capturedAtMs: 300)
        await daemon.delayNextMomentsRequest()

        let refresh = Task { @MainActor in
            await store.loadTimeline(preservingSelection: true)
        }
        try? await Task.sleep(for: .milliseconds(10))
        store.select(index: 1)
        await refresh.value

        XCTAssertEqual(store.moments.map(\.id), ["m1", "m2", "m3"])
        XCTAssertEqual(store.selectedMoment?.id, "m2")
    }
}

private actor RefreshingDaemon: RecallDaemonServing {
    private var storedMoments = [
        RecallMoment(id: "m1", sessionId: "s1", capturedAtMs: 100, imageArtifactId: "a1"),
        RecallMoment(id: "m2", sessionId: "s1", capturedAtMs: 200, imageArtifactId: "a2"),
    ]
    private var shouldDelayNextMomentsRequest = false

    func appendMoment(id: String, capturedAtMs: Int64) {
        storedMoments.append(
            RecallMoment(
                id: id,
                sessionId: "s1",
                capturedAtMs: capturedAtMs,
                imageArtifactId: "artifact-\(id)"
            )
        )
    }

    func delayNextMomentsRequest() {
        shouldDelayNextMomentsRequest = true
    }

    func sessions() async throws -> [RecallSession] {
        [RecallSession(id: "s1", startedAtMs: 100)]
    }

    func timeline() async throws -> [RecallMoment] {
        if shouldDelayNextMomentsRequest {
            shouldDelayNextMomentsRequest = false
            try await Task.sleep(for: .milliseconds(40))
        }
        return storedMoments
    }

    func moments(sessionID _: String) async throws -> [RecallMoment] {
        if shouldDelayNextMomentsRequest {
            shouldDelayNextMomentsRequest = false
            try await Task.sleep(for: .milliseconds(40))
        }
        return storedMoments
    }

    func recallWindow(sessionID _: String, centerMs _: Int64, limit _: Int) async throws -> [RecallMoment] {
        storedMoments
    }

    func artifact(id: String) async throws -> ArtifactPayload {
        ArtifactPayload(id: id, contentType: "image/jpeg", bytesBase64: "")
    }

    func setFavorite(momentID _: String, favorite _: Bool) async throws {}
}

private actor CountingArtifactDaemon: RecallDaemonServing {
    private(set) var requestCount = 0

    func sessions() async throws -> [RecallSession] { [] }
    func timeline() async throws -> [RecallMoment] { [] }
    func moments(sessionID _: String) async throws -> [RecallMoment] { [] }
    func recallWindow(sessionID _: String, centerMs _: Int64, limit _: Int) async throws -> [RecallMoment] { [] }

    func artifact(id: String) async throws -> ArtifactPayload {
        requestCount += 1
        try await Task.sleep(for: .milliseconds(20))
        return ArtifactPayload(
            id: id,
            contentType: "image/jpeg",
            bytesBase64: Data("frame".utf8).base64EncodedString()
        )
    }

    func setFavorite(momentID _: String, favorite _: Bool) async throws {}
}

private actor ConnectionFailingDaemon: RecallDaemonServing {
    func sessions() async throws -> [RecallSession] {
        throw DaemonClientError.connection("Connection refused")
    }

    func timeline() async throws -> [RecallMoment] { [] }
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
        [
            RecallSession(id: "s1", startedAtMs: 100),
            RecallSession(id: "s2", startedAtMs: 200),
        ]
    }

    func timeline() async throws -> [RecallMoment] {
        [
            RecallMoment(id: "m1", sessionId: "s1", capturedAtMs: 100, imageArtifactId: "a1"),
            RecallMoment(id: "m2", sessionId: "s2", capturedAtMs: 200, imageArtifactId: "a2"),
        ]
    }

    func moments(sessionID: String) async throws -> [RecallMoment] {
        try await timeline().filter { $0.sessionId == sessionID }
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
