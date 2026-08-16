import XCTest
@testable import AfterRayRecall

final class ChatAutoScrollStateTests: XCTestCase {
    func testContentGrowthDoesNotDisableFollowing() {
        var state = ChatAutoScrollState()

        state.observe(distanceFromBottom: 240, isUserScrolling: false)

        XCTAssertTrue(state.isFollowingLatest)
        XCTAssertFalse(state.shouldShowLatestButton)
    }

    func testUserScrollingAwayDisablesFollowingAndShowsLatestButton() {
        var state = ChatAutoScrollState()

        state.observe(distanceFromBottom: 120, isUserScrolling: true)

        XCTAssertFalse(state.isFollowingLatest)
        XCTAssertTrue(state.shouldShowLatestButton)
    }

    func testSmallLiveScrollNearBottomKeepsFollowing() {
        var state = ChatAutoScrollState()

        state.observe(
            distanceFromBottom: ChatAutoScrollState.nearBottomThreshold - 1,
            isUserScrolling: true
        )

        XCTAssertTrue(state.isFollowingLatest)
        XCTAssertFalse(state.shouldShowLatestButton)
    }

    func testReturningToBottomResumesFollowing() {
        var state = ChatAutoScrollState()
        state.observe(distanceFromBottom: 120, isUserScrolling: true)

        state.observe(distanceFromBottom: 0, isUserScrolling: true)

        XCTAssertTrue(state.isFollowingLatest)
        XCTAssertFalse(state.shouldShowLatestButton)
    }

    func testLatestButtonAndConversationResetResumeFollowing() {
        var state = ChatAutoScrollState()
        state.observe(distanceFromBottom: 120, isUserScrolling: true)

        state.followLatest()
        XCTAssertTrue(state.isFollowingLatest)

        state.observe(distanceFromBottom: 80, isUserScrolling: true)
        state.resetForConversation()
        XCTAssertEqual(state, ChatAutoScrollState())
    }
}
