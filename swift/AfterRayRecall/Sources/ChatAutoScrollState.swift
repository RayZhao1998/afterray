import CoreGraphics

/// User intent for a growing chat transcript.
///
/// Content growth never disables following by itself. Only a live user scroll
/// can do that, which prevents a streaming token from being mistaken for the
/// user moving away from the answer.
struct ChatAutoScrollState: Equatable, Sendable {
    static let nearBottomThreshold: CGFloat = 40

    private(set) var isFollowingLatest = true
    private(set) var distanceFromBottom: CGFloat = 0

    var shouldShowLatestButton: Bool {
        !isFollowingLatest && distanceFromBottom > Self.nearBottomThreshold
    }

    mutating func observe(distanceFromBottom: CGFloat, isUserScrolling: Bool) {
        self.distanceFromBottom = max(0, distanceFromBottom)
        guard isUserScrolling else { return }
        isFollowingLatest = self.distanceFromBottom <= Self.nearBottomThreshold
    }

    mutating func followLatest() {
        isFollowingLatest = true
    }

    mutating func resetForConversation() {
        isFollowingLatest = true
        distanceFromBottom = 0
    }
}
