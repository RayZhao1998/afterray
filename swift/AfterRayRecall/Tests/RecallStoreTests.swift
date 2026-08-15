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

        XCTAssertEqual(store.loadState, .ready)
    }

    func testStartupFailureIsNotHiddenByConnectionRetry() async {
        let store = RecallStore(daemon: ConnectionFailingDaemon())
        store.reportFailure("afterrayd exited during startup (status 1).\n\nError: key provider: A required entitlement isn't present.")

        await store.loadTimeline()

        XCTAssertEqual(
            store.loadState,
            .failed(
                message: "afterrayd exited during startup (status 1).\n\nError: key provider: A required entitlement isn't present."
            )
        )
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

    func testSystemLockClearsTimelineAndArtifactCache() async throws {
        let timelineDaemon = FakeDaemon()
        let store = RecallStore(daemon: timelineDaemon)
        await store.loadTimeline()
        store.clearSensitiveState()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.moments.isEmpty)
        XCTAssertEqual(store.loadState, .ready)

        let artifactDaemon = CountingArtifactDaemon()
        let repository = RecallImageRepository(daemon: artifactDaemon)
        _ = try await repository.data(artifactID: "frame-1")
        await repository.clearSensitiveData()
        _ = try await repository.data(artifactID: "frame-1")
        let requestCount = await artifactDaemon.requestCount
        XCTAssertEqual(requestCount, 2)
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
            await store.refreshTimeline(preservingSelection: true)
        }
        try? await Task.sleep(for: .milliseconds(10))
        store.select(index: 1)
        await refresh.value

        XCTAssertEqual(store.moments.map(\.id), ["m1", "m2", "m3"])
        XCTAssertEqual(store.selectedMoment?.id, "m2")
    }

    func testRefreshPreservesPlayheadBetweenMoments() async {
        let daemon = RefreshingDaemon()
        let store = RecallStore(daemon: daemon)
        await store.loadTimeline()

        store.select(playheadMs: 150)
        XCTAssertEqual(store.playheadMs, 150)
        XCTAssertEqual(store.selectedMoment?.id, "m1")

        await daemon.appendMoment(id: "m3", capturedAtMs: 300)
        await store.refreshTimeline(preservingSelection: true)

        XCTAssertEqual(store.playheadMs, 150)
        XCTAssertEqual(store.selectedMoment?.id, "m1")
        XCTAssertEqual(store.moments.map(\.id), ["m1", "m2", "m3"])
    }

    func testInitialSummaryHistoryLoadsNewestPageWithoutRepeatingTheDayRequest() async {
        let todayStartMs: Int64 = 1_786_665_600_000
        let yesterdayStartMs = todayStartMs - 86_400_000
        let today = summary(dayStartMs: todayStartMs, title: "Today")
        let yesterday = summary(dayStartMs: yesterdayStartMs, title: "Yesterday")
        let daemon = SummaryHistoryDaemon(
            initialPage: SummaryHistoryPage(
                days: [today, yesterday],
                nextBeforeMs: yesterdayStartMs,
                hasMore: true
            ),
            daySummaries: [today, yesterday]
        )
        let store = RecallStore(daemon: daemon)

        await store.ensureSummaryHistory(containing: todayStartMs, refresh: true)

        XCTAssertEqual(
            store.summaryHistory.map(\.dayStartMs),
            [todayStartMs, yesterdayStartMs]
        )
        let historyCalls = await daemon.summaryHistoryCalls
        XCTAssertEqual(historyCalls.count, 1)
        XCTAssertNil(historyCalls[0], "the first page starts at the newest occupied day")
        let dayCalls = await daemon.daySummaryCalls
        XCTAssertTrue(dayCalls.isEmpty, "the fresh initial page already contains the requested day")
    }

    func testEmptyInitialHistoryIsInitializedOnlyOnce() async {
        let todayStartMs: Int64 = 1_786_665_600_000
        let today = summary(dayStartMs: todayStartMs, title: "Today")
        let daemon = SummaryHistoryDaemon(
            initialPage: SummaryHistoryPage(days: [], nextBeforeMs: nil, hasMore: false),
            daySummaries: [today]
        )
        let store = RecallStore(daemon: daemon)

        await store.ensureSummaryHistory(containing: todayStartMs, refresh: true)
        await store.ensureSummaryHistory(containing: todayStartMs)

        XCTAssertEqual(store.summaryHistory, [today])
        let historyCalls = await daemon.summaryHistoryCalls
        XCTAssertEqual(historyCalls.count, 1, "an empty first page is still an initialized history")
        let dayCalls = await daemon.daySummaryCalls
        XCTAssertEqual(dayCalls, [todayStartMs])
    }

    func testSelectingLoadedOlderDayKeepsNewerDaysAndPaginationCursor() async {
        let todayStartMs: Int64 = 1_786_665_600_000
        let yesterdayStartMs = todayStartMs - 86_400_000
        let olderStartMs = yesterdayStartMs - 86_400_000
        let today = summary(dayStartMs: todayStartMs, title: "Today")
        let yesterday = summary(dayStartMs: yesterdayStartMs, title: "Yesterday")
        let older = summary(dayStartMs: olderStartMs, title: "Older")
        let daemon = SummaryHistoryDaemon(
            initialPage: SummaryHistoryPage(
                days: [today, yesterday],
                nextBeforeMs: yesterdayStartMs,
                hasMore: true
            ),
            olderPages: [
                yesterdayStartMs: SummaryHistoryPage(
                    days: [older],
                    nextBeforeMs: nil,
                    hasMore: false
                )
            ],
            daySummaries: [today, yesterday, older]
        )
        let store = RecallStore(daemon: daemon)

        await store.ensureSummaryHistory(containing: todayStartMs, refresh: true)
        await store.ensureSummaryHistory(containing: yesterdayStartMs)
        await store.loadOlderSummaryHistory()

        XCTAssertEqual(
            store.summaryHistory.map(\.dayStartMs),
            [todayStartMs, yesterdayStartMs, olderStartMs]
        )
        let historyCalls = await daemon.summaryHistoryCalls
        XCTAssertEqual(historyCalls.count, 2)
        XCTAssertNil(historyCalls[0])
        XCTAssertEqual(historyCalls[1], yesterdayStartMs, "date selection must not move the older-page cursor")
        let dayCalls = await daemon.daySummaryCalls
        XCTAssertTrue(dayCalls.isEmpty, "selecting a day already in history needs no second request")
    }

    func testRefreshingLoadedDayReplacesOnlyThatDay() async {
        let todayStartMs: Int64 = 1_786_665_600_000
        let yesterdayStartMs = todayStartMs - 86_400_000
        let today = summary(dayStartMs: todayStartMs, title: "Before refresh")
        let refreshedToday = summary(dayStartMs: todayStartMs, title: "After refresh")
        let yesterday = summary(dayStartMs: yesterdayStartMs, title: "Yesterday")
        let daemon = SummaryHistoryDaemon(
            initialPage: SummaryHistoryPage(
                days: [today, yesterday],
                nextBeforeMs: nil,
                hasMore: false
            ),
            daySummaries: [today, yesterday]
        )
        let store = RecallStore(daemon: daemon)

        await store.ensureSummaryHistory(containing: todayStartMs, refresh: true)
        await daemon.setDaySummary(refreshedToday)
        await store.ensureSummaryHistory(containing: todayStartMs, refresh: true)

        XCTAssertEqual(store.summaryHistory[0], refreshedToday)
        XCTAssertEqual(store.summaryHistory[1], yesterday)
        let dayCalls = await daemon.daySummaryCalls
        XCTAssertEqual(dayCalls, [todayStartMs])
    }

    private func summary(dayStartMs: Int64, title: String) -> DaySummary {
        DaySummary(
            day: DaySummaryLayout.localDayKey(ms: dayStartMs),
            dayStartMs: dayStartMs,
            dayEndMs: dayStartMs + 86_400_000,
            slots: [
                DaySlotSummary(
                    slotStartMs: dayStartMs,
                    slotEndMs: dayStartMs + DaySummaryLayout.slotDurationMs,
                    state: "done",
                    facts: DaySlotFacts(apps: []),
                    title: title
                )
            ]
        )
    }
}

private actor SummaryHistoryDaemon: RecallDaemonServing {
    private let initialPage: SummaryHistoryPage
    private let olderPages: [Int64: SummaryHistoryPage]
    private var daySummaries: [String: DaySummary]
    private(set) var daySummaryCalls: [Int64] = []
    private(set) var summaryHistoryCalls: [Int64?] = []

    init(
        initialPage: SummaryHistoryPage,
        olderPages: [Int64: SummaryHistoryPage] = [:],
        daySummaries: [DaySummary]
    ) {
        self.initialPage = initialPage
        self.olderPages = olderPages
        self.daySummaries = Dictionary(
            daySummaries.map { ($0.day, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func setDaySummary(_ summary: DaySummary) {
        daySummaries[summary.day] = summary
    }

    func daySummary(dayMs: Int64) async throws -> DaySummary {
        daySummaryCalls.append(dayMs)
        return daySummaries[DaySummaryLayout.localDayKey(ms: dayMs)] ?? .empty
    }

    func summaryHistory(beforeMs: Int64?, limit _: Int) async throws -> SummaryHistoryPage {
        summaryHistoryCalls.append(beforeMs)
        guard let beforeMs else { return initialPage }
        return olderPages[beforeMs] ?? SummaryHistoryPage(days: [], nextBeforeMs: nil, hasMore: false)
    }

    func sessions() async throws -> [RecallSession] { [] }
    func timeline() async throws -> [RecallMoment] { [] }
    func timeline(sinceMs _: Int64) async throws -> [RecallMoment] { [] }
    func moments(sessionID _: String) async throws -> [RecallMoment] { [] }
    func recallWindow(sessionID _: String, centerMs _: Int64, limit _: Int) async throws -> [RecallMoment] { [] }
    func artifact(id: String) async throws -> ArtifactPayload {
        ArtifactPayload(id: id, contentType: "application/octet-stream", bytes: Data())
    }
    func setFavorite(momentID _: String, favorite _: Bool) async throws {}
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
        storedMoments
    }

    func timeline(sinceMs: Int64) async throws -> [RecallMoment] {
        if shouldDelayNextMomentsRequest {
            shouldDelayNextMomentsRequest = false
            try await Task.sleep(for: .milliseconds(40))
        }
        return storedMoments.filter { $0.capturedAtMs >= sinceMs }
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
        ArtifactPayload(id: id, contentType: "image/jpeg", bytes: Data())
    }

    func setFavorite(momentID _: String, favorite _: Bool) async throws {}
}

private actor CountingArtifactDaemon: RecallDaemonServing {
    private(set) var requestCount = 0

    func sessions() async throws -> [RecallSession] { [] }
    func timeline() async throws -> [RecallMoment] { [] }
    func timeline(sinceMs _: Int64) async throws -> [RecallMoment] { [] }
    func moments(sessionID _: String) async throws -> [RecallMoment] { [] }
    func recallWindow(sessionID _: String, centerMs _: Int64, limit _: Int) async throws -> [RecallMoment] { [] }

    func artifact(id: String) async throws -> ArtifactPayload {
        requestCount += 1
        try await Task.sleep(for: .milliseconds(20))
        return ArtifactPayload(
            id: id,
            contentType: "image/jpeg",
            bytes: Data("frame".utf8)
        )
    }

    func setFavorite(momentID _: String, favorite _: Bool) async throws {}
}

private actor ConnectionFailingDaemon: RecallDaemonServing {
    func sessions() async throws -> [RecallSession] {
        throw DaemonClientError.connection("Connection refused")
    }

    func timeline() async throws -> [RecallMoment] { [] }
    func timeline(sinceMs _: Int64) async throws -> [RecallMoment] { [] }
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

    func timeline(sinceMs: Int64) async throws -> [RecallMoment] {
        try await timeline().filter { $0.capturedAtMs >= sinceMs }
    }

    func moments(sessionID: String) async throws -> [RecallMoment] {
        try await timeline().filter { $0.sessionId == sessionID }
    }

    func recallWindow(sessionID: String, centerMs: Int64, limit: Int) async throws -> [RecallMoment] {
        try await moments(sessionID: sessionID)
    }

    func artifact(id: String) async throws -> ArtifactPayload {
        ArtifactPayload(id: id, contentType: "image/png", bytes: Data())
    }

    func setFavorite(momentID: String, favorite: Bool) async throws {
        favoriteCalls.append(.init(momentID: momentID, favorite: favorite))
    }
}
