import CoreGraphics

struct ChatScrollMetrics: Equatable, Sendable {
    let distanceFromBottom: CGFloat
    let isUserScrolling: Bool
}
