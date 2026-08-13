import CoreGraphics
import Foundation

public struct AppUsageIdentity: Equatable, Hashable, Sendable {
    public let name: String
    public let bundleIdentifier: String?

    public init(name: String, bundleIdentifier: String?) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }

    public static func of(_ moment: RecallMoment) -> AppUsageIdentity {
        AppUsageIdentity(
            name: moment.applicationName ?? "Unknown app",
            bundleIdentifier: moment.bundleIdentifier
        )
    }
}

public struct AppUsageRun: Equatable, Identifiable, Sendable {
    public let id: Int
    public let identity: AppUsageIdentity
    public let startMs: Int64
    public let endMs: Int64
    public let startIndex: Int
    public let endIndex: Int
    public let startX: CGFloat
    public let width: CGFloat

    public var applicationName: String { identity.name }
    public var bundleIdentifier: String? { identity.bundleIdentifier }
    public var durationMs: Int64 { max(endMs - startMs, 1) }
    public var endX: CGFloat { startX + width }

    public func contains(ms: Int64, isLast: Bool) -> Bool {
        if isLast { return ms >= startMs && ms <= endMs }
        return ms >= startMs && ms < endMs
    }

    public func contains(x: CGFloat, isLast: Bool) -> Bool {
        if isLast { return x >= startX && x <= endX }
        return x >= startX && x < endX
    }
}

/// Single mapping from wall-clock time to timeline x, and back.
///
/// Short app-switch runs can be inflated to a minimum width, but that warp is
/// part of this function. Playhead, colored runs, hits, and drag all use it.
public struct TimelineLayout: Equatable, Sendable {
    public let moments: [RecallMoment]
    public let runs: [AppUsageRun]
    public let startMs: Int64
    public let endMs: Int64
    public let contentWidth: CGFloat

    public static let minimumSegmentWidth: CGFloat = 5

    public init(
        moments: [RecallMoment],
        viewportWidth: CGFloat,
        density: Double,
        minimumSegmentWidth: CGFloat = TimelineLayout.minimumSegmentWidth
    ) {
        self.moments = moments
        let bounds = Self.timeBounds(moments: moments)
        startMs = bounds.startMs
        endMs = bounds.endMs

        let rawRuns = Self.makeRuns(moments: moments, endMs: bounds.endMs)
        let totalDuration = max(bounds.endMs - bounds.startMs, 1)
        let seconds = CGFloat(totalDuration) / 1_000
        let baseWidth = max(max(viewportWidth, 1) * 1.18, min(seconds * CGFloat(density), 9_000))

        var cursor: CGFloat = 0
        var placed: [AppUsageRun] = []
        placed.reserveCapacity(rawRuns.count)
        for raw in rawRuns {
            let natural = baseWidth * CGFloat(raw.durationMs) / CGFloat(totalDuration)
            let width = max(natural, minimumSegmentWidth)
            placed.append(
                AppUsageRun(
                    id: raw.id,
                    identity: raw.identity,
                    startMs: raw.startMs,
                    endMs: raw.endMs,
                    startIndex: raw.startIndex,
                    endIndex: raw.endIndex,
                    startX: cursor,
                    width: width
                )
            )
            cursor += width
        }
        runs = placed
        contentWidth = max(cursor, 1)
    }

    public static func timeBounds(moments: [RecallMoment]) -> (startMs: Int64, endMs: Int64) {
        guard let first = moments.first, let last = moments.last else {
            return (0, 1)
        }
        let intervals = zip(moments, moments.dropFirst())
            .map { max($1.capturedAtMs - $0.capturedAtMs, 1_000) }
            .sorted()
        let trailingInterval = intervals.isEmpty ? 10_000 : intervals[intervals.count / 2]
        return (first.capturedAtMs, last.capturedAtMs + min(trailingInterval, 60_000))
    }

    public func x(ms: Int64) -> CGFloat {
        if ms <= startMs { return 0 }
        if ms >= endMs { return contentWidth }
        guard let run = run(containingMs: ms) else { return contentWidth }
        let duration = CGFloat(max(run.endMs - run.startMs, 1))
        let t = CGFloat(ms - run.startMs) / duration
        return run.startX + t * run.width
    }

    public func ms(x: CGFloat) -> Int64 {
        if x <= 0 { return startMs }
        if x >= contentWidth { return endMs }
        guard let run = run(atX: x) else { return endMs }
        let t = Double((x - run.startX) / max(run.width, 0.000_1))
        let clamped = min(max(t, 0), 1)
        let value = run.startMs + Int64((Double(run.endMs - run.startMs) * clamped).rounded())
        return min(max(value, run.startMs), run.endMs)
    }

    public func playheadX(playheadMs: Int64, isLive: Bool) -> CGFloat {
        x(ms: isLive ? endMs : playheadMs)
    }

    public func run(containingMs ms: Int64) -> AppUsageRun? {
        guard let last = runs.last else { return nil }
        if let match = runs.dropLast().first(where: { $0.contains(ms: ms, isLast: false) }) {
            return match
        }
        if last.contains(ms: ms, isLast: true) || ms >= last.startMs {
            return last
        }
        return runs.first
    }

    public func run(atX x: CGFloat) -> AppUsageRun? {
        guard let last = runs.last else { return nil }
        if let match = runs.dropLast().first(where: { $0.contains(x: x, isLast: false) }) {
            return match
        }
        if last.contains(x: x, isLast: true) || x >= last.startX {
            return last
        }
        return runs.first
    }

    public func clamp(_ playheadMs: Int64) -> Int64 {
        min(max(playheadMs, startMs), endMs)
    }

    private struct RawRun {
        let id: Int
        let identity: AppUsageIdentity
        let startMs: Int64
        let endMs: Int64
        let startIndex: Int
        let endIndex: Int
        var durationMs: Int64 { max(endMs - startMs, 1) }
    }

    private static func makeRuns(moments: [RecallMoment], endMs: Int64) -> [RawRun] {
        guard !moments.isEmpty else { return [] }
        var collected: [RawRun] = []
        var runStart = 0
        for index in 1...moments.count {
            let endsRun = index == moments.count
                || AppUsageIdentity.of(moments[index]) != AppUsageIdentity.of(moments[runStart])
            guard endsRun else { continue }
            let runEndMs = index < moments.count ? moments[index].capturedAtMs : endMs
            collected.append(
                RawRun(
                    id: collected.count,
                    identity: .of(moments[runStart]),
                    startMs: moments[runStart].capturedAtMs,
                    endMs: runEndMs,
                    startIndex: runStart,
                    endIndex: index - 1
                )
            )
            runStart = index
        }
        return collected
    }
}

public enum RecallPlayhead {
    /// Last captured frame at or before `playheadMs`. Empty timelines resolve to nil.
    public static func resolve(playheadMs: Int64, moments: [RecallMoment]) -> RecallMoment? {
        guard let index = resolveIndex(playheadMs: playheadMs, moments: moments) else { return nil }
        return moments[index]
    }

    public static func resolveIndex(playheadMs: Int64, moments: [RecallMoment]) -> Int? {
        guard !moments.isEmpty else { return nil }
        if playheadMs < moments[0].capturedAtMs { return 0 }
        var resolved = 0
        for (index, moment) in moments.enumerated() {
            if moment.capturedAtMs <= playheadMs {
                resolved = index
            } else {
                break
            }
        }
        return resolved
    }

    public static func clamp(_ playheadMs: Int64, moments: [RecallMoment]) -> Int64 {
        let bounds = TimelineLayout.timeBounds(moments: moments)
        guard !moments.isEmpty else { return 0 }
        return min(max(playheadMs, bounds.startMs), bounds.endMs)
    }

    /// Drag / precise scroll: move the playhead by `deltaX` timeline points.
    /// Positive `deltaX` travels backward in time (content moves right).
    public static func move(
        playheadMs: Int64,
        isLive: Bool,
        deltaX: CGFloat,
        layout: TimelineLayout
    ) -> (playheadMs: Int64, isLive: Bool) {
        guard !layout.moments.isEmpty else { return (playheadMs, isLive) }
        let originX = layout.playheadX(playheadMs: playheadMs, isLive: isLive)
        let ms = layout.ms(x: originX - deltaX)
        if ms >= layout.endMs {
            return (layout.moments[layout.moments.count - 1].capturedAtMs, true)
        }
        return (ms, false)
    }

    public static func stepMoment(
        playheadMs: Int64,
        isLive: Bool,
        delta: Int,
        moments: [RecallMoment]
    ) -> (playheadMs: Int64, isLive: Bool) {
        guard !moments.isEmpty else { return (playheadMs, isLive) }
        let current = isLive
            ? moments.count
            : (resolveIndex(playheadMs: playheadMs, moments: moments) ?? 0)
        let next = current + delta
        if next >= moments.count {
            return (moments[moments.count - 1].capturedAtMs, true)
        }
        if next < 0 {
            return (moments[0].capturedAtMs, false)
        }
        return (moments[next].capturedAtMs, false)
    }
}

enum RecallDisplayedFrame {
    static func choose<Frame>(
        artifactID: String,
        cached: Frame?,
        loadedID: String?,
        loadedFrame: Frame?
    ) -> Frame? {
        if let cached { return cached }
        if loadedID == artifactID { return loadedFrame }
        return loadedFrame
    }
}
