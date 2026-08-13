import XCTest
@testable import AfterRayRecall

final class TimelineLayoutTests: XCTestCase {
    func testMappingIsInvertibleAcrossInflatedShortRuns() {
        let moments = clusteredShortSwitchesThenLongRun()
        let layout = TimelineLayout(moments: moments, viewportWidth: 1_000, density: 0.12)

        var time = layout.startMs
        while time <= layout.endMs {
            let x = layout.x(ms: time)
            XCTAssertEqual(layout.ms(x: x), time, "ms(x(t)) must round-trip at \(time)")
            time += 1_000
        }

        var x: CGFloat = 0
        while x <= layout.contentWidth {
            let ms = layout.ms(x: x)
            XCTAssertEqual(layout.x(ms: ms), x, accuracy: 0.6, "x(ms(x)) must round-trip at \(x)")
            x += 17
        }
    }

    func testNeedleStaysInsideOwnRunWithManyShortAppSwitches() throws {
        let moments = clusteredShortSwitchesThenLongRun()
        let layout = TimelineLayout(moments: moments, viewportWidth: 1_000, density: 0.12)
        XCTAssertGreaterThan(layout.runs.count, 40)

        for moment in moments {
            let runByTime = try XCTUnwrap(layout.run(containingMs: moment.capturedAtMs))
            XCTAssertEqual(runByTime.identity, AppUsageIdentity.of(moment))

            let x = layout.x(ms: moment.capturedAtMs)
            let runByX = try XCTUnwrap(layout.run(atX: x))
            XCTAssertEqual(
                runByX.identity,
                AppUsageIdentity.of(moment),
                "playhead at \(moment.capturedAtMs) sits in \(runByX.applicationName) instead of \(moment.applicationName ?? "?")"
            )
        }
    }

    func testLegacyHStackMinWidthFormulaDesynchronizesNeedleFromRuns() {
        let moments = clusteredShortSwitchesThenLongRun()
        let bounds = TimelineLayout.timeBounds(moments: moments)
        let total = max(bounds.endMs - bounds.startMs, 1)
        let contentWidth: CGFloat = 1_000
        let gap: CGFloat = 2
        let runs = TimelineLayout(moments: moments, viewportWidth: contentWidth, density: 0.12).runs

        var cursor: CGFloat = 0
        var mismatched = 0
        for (index, run) in runs.enumerated() {
            let fraction = CGFloat(run.durationMs) / CGFloat(total)
            let visualWidth = max(contentWidth * fraction - gap, 5)
            let visualStart = cursor
            cursor += visualWidth + (index == runs.count - 1 ? 0 : gap)

            let sample = moments[run.startIndex]
            let timeX = contentWidth * CGFloat(sample.capturedAtMs - bounds.startMs) / CGFloat(total)
            if timeX < visualStart || timeX > visualStart + visualWidth {
                mismatched += 1
            }
        }

        XCTAssertGreaterThan(
            mismatched,
            0,
            "The old HStack + min-width layout must stay observably wrong so we do not bring it back"
        )
    }

    func testApplicationNameChangeSplitsRunsWithoutChangingCountOrEndpoints() {
        let first = moment(id: "a", at: 0, app: "Safari", bundle: "safari")
        let middle = moment(id: "b", at: 10_000, app: "Safari", bundle: "safari")
        let last = moment(id: "c", at: 20_000, app: "Safari", bundle: "safari")
        let before = TimelineLayout(
            moments: [first, middle, last],
            viewportWidth: 800,
            density: 0.12
        )
        XCTAssertEqual(before.runs.count, 1)

        let splitMiddle = moment(id: "b", at: 10_000, app: "Xcode", bundle: "xcode")
        let after = TimelineLayout(
            moments: [first, splitMiddle, last],
            viewportWidth: 800,
            density: 0.12
        )
        XCTAssertEqual(after.moments.count, before.moments.count)
        XCTAssertEqual(after.moments.first?.id, before.moments.first?.id)
        XCTAssertEqual(after.moments.last?.id, before.moments.last?.id)
        XCTAssertEqual(after.runs.map(\.applicationName), ["Safari", "Xcode", "Safari"])
    }

    func testClickUsesTimeUnderCursorNotRunCenter() throws {
        let moments = [
            moment(id: "s1", at: 0, app: "Safari", bundle: "safari"),
            moment(id: "s2", at: 1_000, app: "Safari", bundle: "safari"),
            moment(id: "x1", at: 3_600_000, app: "Xcode", bundle: "xcode"),
        ]
        let layout = TimelineLayout(moments: moments, viewportWidth: 1_000, density: 0.12)
        let safari = try XCTUnwrap(layout.runs.first)
        let clickX = safari.startX + safari.width * 0.1
        let playheadMs = layout.ms(x: clickX)
        let resolved = try XCTUnwrap(RecallPlayhead.resolve(playheadMs: playheadMs, moments: moments))
        XCTAssertEqual(resolved.applicationName, "Safari")
        XCTAssertNotEqual(resolved.id, moments[safari.startIndex + (safari.endIndex - safari.startIndex) / 2].id)
    }

    func testResolveAndMoveShareOneMomentWithTheNeedle() throws {
        let moments = clusteredShortSwitchesThenLongRun()
        let layout = TimelineLayout(moments: moments, viewportWidth: 1_000, density: 0.12)
        var playheadMs = moments[10].capturedAtMs
        var isLive = false

        let moved = RecallPlayhead.move(
            playheadMs: playheadMs,
            isLive: isLive,
            deltaX: 80,
            layout: layout
        )
        playheadMs = moved.playheadMs
        isLive = moved.isLive

        let resolved = try XCTUnwrap(RecallPlayhead.resolve(playheadMs: playheadMs, moments: moments))
        let needleRun = try XCTUnwrap(layout.run(atX: layout.playheadX(playheadMs: playheadMs, isLive: isLive)))
        XCTAssertEqual(needleRun.identity, AppUsageIdentity.of(resolved))
        XCTAssertEqual(resolved.imageArtifactId, "frame-\(resolved.id)")
        XCTAssertFalse(isLive)
    }

    func testDisplayedFrameKeepsPreviousArtifactUntilTheNextOneArrives() {
        XCTAssertEqual(
            RecallDisplayedFrame.choose(
                artifactID: "B",
                cached: nil as String?,
                loadedID: "A",
                loadedFrame: "frame-A"
            ),
            "frame-A"
        )
        XCTAssertEqual(
            RecallDisplayedFrame.choose(
                artifactID: "B",
                cached: "cached-B",
                loadedID: "A",
                loadedFrame: "frame-A"
            ),
            "cached-B"
        )
        XCTAssertEqual(
            RecallDisplayedFrame.choose(
                artifactID: "B",
                cached: nil as String?,
                loadedID: "B",
                loadedFrame: "frame-B"
            ),
            "frame-B"
        )
    }

    func testLeavingLiveMovesByTimelinePointsAndEnteringLiveSnapsToEnd() {
        let moments = [
            moment(id: "a", at: 0, app: "Safari", bundle: "safari"),
            moment(id: "b", at: 10_000, app: "Xcode", bundle: "xcode"),
        ]
        let layout = TimelineLayout(moments: moments, viewportWidth: 800, density: 0.2)

        let intoHistory = RecallPlayhead.move(
            playheadMs: moments[1].capturedAtMs,
            isLive: true,
            deltaX: 20,
            layout: layout
        )
        XCTAssertFalse(intoHistory.isLive)
        XCTAssertLessThan(intoHistory.playheadMs, layout.endMs)

        let backToNow = RecallPlayhead.move(
            playheadMs: intoHistory.playheadMs,
            isLive: false,
            deltaX: -10_000,
            layout: layout
        )
        XCTAssertTrue(backToNow.isLive)
        XCTAssertEqual(backToNow.playheadMs, moments[1].capturedAtMs)
    }

    func testIdleGapSplitsDistantMomentsAndCapsWidth() {
        let moments = [
            moment(id: "s1", at: 0, app: "Safari", bundle: "safari"),
            moment(id: "s2", at: 10_000, app: "Safari", bundle: "safari"),
            moment(id: "x1", at: 3_610_000, app: "Xcode", bundle: "xcode"),
        ]
        let layout = TimelineLayout(moments: moments, viewportWidth: 1_000, density: 0.12)
        XCTAssertEqual(layout.runs.map(\.isIdle), [false, true, false])
        XCTAssertEqual(layout.runs.map(\.applicationName), ["Safari", "休眠", "Xcode"])
        let idle = layout.runs[1]
        XCTAssertLessThanOrEqual(idle.durationMs, 3_610_000)
        let idleVisualShare = idle.width / layout.contentWidth
        XCTAssertLessThan(idleVisualShare, 0.85, "hour-long lock must not dominate the timeline")
    }

    func testResolveIsNilInsideIdleGap() {
        let moments = [
            moment(id: "s1", at: 0, app: "Safari", bundle: "safari"),
            moment(id: "x1", at: 3_600_000, app: "Xcode", bundle: "xcode"),
        ]
        XCTAssertEqual(RecallPlayhead.resolve(playheadMs: 0, moments: moments)?.id, "s1")
        XCTAssertNil(RecallPlayhead.resolve(playheadMs: 60_000, moments: moments))
        XCTAssertEqual(RecallPlayhead.resolve(playheadMs: 3_600_000, moments: moments)?.id, "x1")
    }

    func testStepMomentUsesDiscreteSamples() {
        let moments = [
            moment(id: "a", at: 0, app: "Safari", bundle: "safari"),
            moment(id: "b", at: 10_000, app: "Xcode", bundle: "xcode"),
        ]
        let fromLive = RecallPlayhead.stepMoment(
            playheadMs: 10_000,
            isLive: true,
            delta: -1,
            moments: moments
        )
        XCTAssertFalse(fromLive.isLive)
        XCTAssertEqual(fromLive.playheadMs, 10_000)

        let toLive = RecallPlayhead.stepMoment(
            playheadMs: 10_000,
            isLive: false,
            delta: 1,
            moments: moments
        )
        XCTAssertTrue(toLive.isLive)
    }

    private func clusteredShortSwitchesThenLongRun() -> [RecallMoment] {
        var moments: [RecallMoment] = []
        for index in 0..<50 {
            moments.append(
                moment(
                    id: "short-\(index)",
                    at: Int64(index) * 1_000,
                    app: "App \(index)",
                    bundle: "app.\(index)"
                )
            )
        }
        moments.append(
            moment(id: "long", at: 50_000, app: "Xcode", bundle: "com.apple.dt.Xcode")
        )
        return moments
    }

    private func moment(
        id: String,
        at capturedAtMs: Int64,
        app: String,
        bundle: String
    ) -> RecallMoment {
        RecallMoment(
            id: id,
            sessionId: "s",
            capturedAtMs: capturedAtMs,
            imageArtifactId: "frame-\(id)",
            applicationName: app,
            bundleIdentifier: bundle
        )
    }
}
