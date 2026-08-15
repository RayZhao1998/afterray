import AppKit
import Foundation
import SwiftUI

/// iOS-style deceleration for the timeline scrub.
///
/// The previous pipeline capped the pending accumulator at ±160 points and
/// released at most 40 points per frame — a hard ceiling of ~4800 pt/s that
/// discarded most of every hard flick. This model does what a scroll view
/// does instead: gesture deltas move content 1:1, a release converts recent
/// gesture speed into velocity, and velocity decays exponentially. Because a
/// same-direction release *adds* to whatever velocity is still live,
/// repeated flicks stack and the scrub genuinely accelerates.
public struct ScrubInertia: Equatable, Sendable {
    public private(set) var velocity: Double = 0 // points per second

    /// Exponential decay rate. ~2.6 lands near UIScrollView's normal
    /// deceleration feel at trackpad speeds.
    public static let friction: Double = 2.6
    public static let maximumVelocity: Double = 30_000
    /// Below this the glide reads as stopped; snap to zero instead of
    /// trickling sub-pixel movement forever.
    public static let restThreshold: Double = 14

    public init() {}

    public var isCoasting: Bool { velocity != 0 }

    /// A finger-up release measured at `pointsPerSecond`. Same-direction
    /// releases stack — that is the repeated-flick acceleration — while an
    /// opposite-direction release brakes straight to the new direction.
    public mutating func release(pointsPerSecond: Double) {
        guard pointsPerSecond.isFinite else { return }
        if velocity != 0, velocity.sign != pointsPerSecond.sign {
            velocity = pointsPerSecond
        } else {
            velocity += pointsPerSecond
        }
        velocity = velocity.clamped(to: Self.maximumVelocity)
    }

    /// Direct gesture input while gliding: same direction lets the glide
    /// keep carrying underneath the finger; opposite direction is a grab —
    /// the glide stops and the finger owns the motion.
    public mutating func fingerMoved(delta: Double) {
        if velocity != 0, delta != 0, velocity.sign != delta.sign {
            velocity = 0
        }
    }

    /// Advances one display-link tick; returns the distance to glide.
    public mutating func step(dt: TimeInterval) -> Double {
        guard dt > 0, velocity.magnitude > Self.restThreshold else {
            velocity = 0
            return 0
        }
        let decay = exp(-Self.friction * dt)
        // Closed-form integral of v·e^(−kt) over the tick: exact regardless
        // of frame-rate wobble.
        let travelled = velocity * (1 - decay) / Self.friction
        velocity *= decay
        return travelled
    }

    public mutating func stop() {
        velocity = 0
    }
}

extension Double {
    fileprivate func clamped(to magnitude: Double) -> Double {
        Swift.max(-magnitude, Swift.min(magnitude, self))
    }
}

/// Estimates release velocity from the trailing gesture deltas, the way a
/// scroll view samples the last few frames of a drag rather than the whole
/// gesture.
public struct FlickSampler: Sendable {
    private var samples: [(time: TimeInterval, delta: Double)] = []
    /// Window over which release speed is measured.
    public static let window: TimeInterval = 0.09

    public init() {}

    public mutating func record(delta: Double, at time: TimeInterval) {
        samples.append((time, delta))
        trim(now: time)
    }

    public mutating func releaseVelocity(at time: TimeInterval) -> Double {
        trim(now: time)
        defer { samples.removeAll() }
        guard let first = samples.first else { return 0 }
        let span = max(time - first.time, 1.0 / 120.0)
        let distance = samples.reduce(0.0) { $0 + $1.delta }
        return distance / span
    }

    public mutating func reset() {
        samples.removeAll()
    }

    private mutating func trim(now: TimeInterval) {
        samples.removeAll { now - $0.time > Self.window }
    }
}

/// Registry of screen regions whose scroll events belong to the region — a
/// panel with its own scroll view — and must never scrub the timeline.
/// Views register from SwiftUI via `ScrollFenceView`; the global scroll
/// monitor asks before touching an event.
@MainActor
public final class ScrollFenceRegistry {
    public static let shared = ScrollFenceRegistry()
    private var fences: [WeakView] = []

    private struct WeakView {
        weak var view: NSView?
    }

    public func register(_ view: NSView) {
        prune()
        fences.append(WeakView(view: view))
    }

    public func contains(windowPoint: NSPoint, in window: NSWindow) -> Bool {
        prune()
        return fences.contains { holder in
            guard let view = holder.view, view.window === window, !view.isHiddenOrHasHiddenAncestor
            else { return false }
            return view.convert(view.bounds, to: nil).contains(windowPoint)
        }
    }

    /// Whether the pointer currently rests inside any fence — used to stop
    /// programmatic auto-scrolls from yanking a panel the user is reading.
    public func pointerInsideAnyFence() -> Bool {
        prune()
        return fences.contains { holder in
            guard let view = holder.view, let window = view.window,
                  !view.isHiddenOrHasHiddenAncestor
            else { return false }
            let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            return view.convert(view.bounds, to: nil).contains(point)
        }
    }

    private func prune() {
        fences.removeAll { $0.view == nil }
    }
}

/// Invisible marker: mount as `.background(ScrollFenceView())` on any region
/// whose scrolls the timeline must leave alone.
public struct ScrollFenceView: NSViewRepresentable {
    public init() {}

    public func makeNSView(context _: Context) -> NSView {
        let view = FenceView()
        ScrollFenceRegistry.shared.register(view)
        return view
    }

    public func updateNSView(_: NSView, context _: Context) {}

    private final class FenceView: NSView {
        override func hitTest(_: NSPoint) -> NSView? { nil }
    }
}
