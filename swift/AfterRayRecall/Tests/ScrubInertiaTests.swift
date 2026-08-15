import XCTest
@testable import AfterRayRecall

final class ScrubInertiaTests: XCTestCase {
    /// The reported feel: repeated same-direction swipes must accelerate.
    func testRepeatedFlicksStackVelocity() {
        var inertia = ScrubInertia()
        inertia.release(pointsPerSecond: 3_000)
        let afterOne = inertia.velocity
        _ = inertia.step(dt: 0.1) // decays a little
        inertia.release(pointsPerSecond: 3_000)
        XCTAssertGreaterThan(
            inertia.velocity,
            afterOne,
            "a second flick must build on the live glide, not restart it"
        )
    }

    func testOppositeFlickBrakesToTheNewDirection() {
        var inertia = ScrubInertia()
        inertia.release(pointsPerSecond: 5_000)
        inertia.release(pointsPerSecond: -2_000)
        XCTAssertEqual(inertia.velocity, -2_000, accuracy: 0.001)
    }

    func testOppositeDragGrabsTheGlide() {
        var inertia = ScrubInertia()
        inertia.release(pointsPerSecond: 5_000)
        inertia.fingerMoved(delta: -3)
        XCTAssertEqual(inertia.velocity, 0, "an opposite-direction touch must stop the glide")
    }

    func testSameDirectionDragKeepsTheGlide() {
        var inertia = ScrubInertia()
        inertia.release(pointsPerSecond: 5_000)
        inertia.fingerMoved(delta: 4)
        XCTAssertGreaterThan(inertia.velocity, 0)
    }

    func testGlideDecaysToRestAndStops() {
        var inertia = ScrubInertia()
        inertia.release(pointsPerSecond: 8_000)
        var total = 0.0
        var steps = 0
        while inertia.isCoasting, steps < 2_000 {
            total += inertia.step(dt: 1.0 / 120.0)
            steps += 1
        }
        XCTAssertFalse(inertia.isCoasting, "friction must bring the glide to rest")
        // Closed form: distance = v0/k ≈ 8000/2.6 ≈ 3077, minus the tail cut
        // off at the rest threshold.
        XCTAssertEqual(total, 8_000 / ScrubInertia.friction, accuracy: 40)
        XCTAssertLessThan(steps, 600, "decay should settle in a few seconds, not minutes")
    }

    func testStepIntegralMatchesClosedFormRegardlessOfFrameRate() {
        var at120 = ScrubInertia()
        var at60 = ScrubInertia()
        at120.release(pointsPerSecond: 6_000)
        at60.release(pointsPerSecond: 6_000)
        var distance120 = 0.0
        var distance60 = 0.0
        for _ in 0..<120 { distance120 += at120.step(dt: 1.0 / 120.0) }
        for _ in 0..<60 { distance60 += at60.step(dt: 1.0 / 60.0) }
        XCTAssertEqual(
            distance120,
            distance60,
            accuracy: 0.5,
            "one second of glide must travel the same distance at any frame rate"
        )
    }

    func testVelocityIsClamped() {
        var inertia = ScrubInertia()
        for _ in 0..<100 {
            inertia.release(pointsPerSecond: 20_000)
        }
        XCTAssertEqual(inertia.velocity, ScrubInertia.maximumVelocity)
    }

    func testFlickSamplerMeasuresTrailingWindowOnly() {
        var sampler = FlickSampler()
        // Old, slow movement well outside the window…
        sampler.record(delta: 2, at: 0.0)
        // …then a fast finish.
        for index in 0..<6 {
            sampler.record(delta: 30, at: 1.0 + Double(index) * 0.01)
        }
        let velocity = sampler.releaseVelocity(at: 1.06)
        XCTAssertGreaterThan(velocity, 2_000, "trailing speed defines the flick, got \(velocity)")
        // Second read after reset yields nothing.
        XCTAssertEqual(sampler.releaseVelocity(at: 1.1), 0)
    }

    func testDaySlotDecodesAnchorMomentId() throws {
        let json = """
        {"slot_start_ms":10,"slot_end_ms":20,"state":"done",
         "anchor_moment_id":"m-anchor","facts":{"apps":[],"moment_count":3}}
        """
        let slot = try JSONDecoder().decode(DaySlotSummary.self, from: Data(json.utf8))
        XCTAssertEqual(slot.anchorMomentId, "m-anchor")

        let legacy = """
        {"slot_start_ms":10,"slot_end_ms":20,"state":"done","facts":{"apps":[]}}
        """
        let old = try JSONDecoder().decode(DaySlotSummary.self, from: Data(legacy.utf8))
        XCTAssertNil(old.anchorMomentId)
    }
}
