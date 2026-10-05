import XCTest
@testable import ScrollpageCore

private extension Rig {
    /// Changes the palm's width ratio by `fraction` of its rest width (negative
    /// palm up), the knuckles staying in place.
    func twist(by fraction: Double, over duration: Double) {
        let from = pose.palmWidth
        run(duration) { p, pose in pose.palmWidth = from * (1 + fraction * minimumJerk(p)) }
    }
}

final class ForearmTwistTests: XCTestCase {
    private func pinched(seed: UInt64 = 1, webcam: Bool = false) -> Rig {
        let rig = webcam ? Rig.webcam(seed: seed, fps: 30) : Rig(seed: seed)
        rig.hold(2)
        rig.pinch(true, over: 0.08)
        rig.hold(0.3)
        rig.clearOutputs()
        return rig
    }

    func testWidthRatioOfTheSyntheticHand() {
        var gen = SyntheticHand(sigma: 0)
        var pose = HandPose()
        XCTAssertEqual(ForearmTwist.widthRatio(gen.sample(pose), minConfidence: 0.5)!, 0.6, accuracy: 0.01)
        pose.palmWidth = 0.5
        XCTAssertEqual(ForearmTwist.widthRatio(gen.sample(pose), minConfidence: 0.5)!, 0.3, accuracy: 0.01)
        pose.hidden = [.littleMCP]
        XCTAssertNil(ForearmTwist.widthRatio(gen.sample(pose), minConfidence: 0.5))
    }

    /// Palm toward the ceiling narrows the edge-on palm and moves the pointer
    /// up; toward the floor widens it and moves it down.
    func testRollingMovesThePointerVertically() {
        let up = pinched()
        up.twist(by: -0.3, over: 0.4)
        up.hold(0.2)
        let rise = up.pointerTravel().net
        XCTAssertLessThan(rise.y, -50)
        XCTAssertLessThan(abs(rise.x), 0.2 * abs(rise.y))

        let down = pinched()
        down.twist(by: 0.12, over: 0.4)
        down.hold(0.2)
        let fall = down.pointerTravel().net
        XCTAssertGreaterThan(fall.y, 50)
        XCTAssertLessThan(abs(fall.x), 0.2 * fall.y)
    }

    /// The palm narrows up to 45 % rolling up but widens only 17 % rolling
    /// down: each side has its own range, so a full roll either way moves as
    /// far, on average over the noise.
    func testEachDirectionHasItsOwnGain() {
        let c = ForearmTwistConfig()
        let up = mean { seed in
            let rig = pinched(seed: seed)
            rig.twist(by: -0.6 * c.upRange, over: 0.4)
            rig.hold(0.2)
            return -rig.pointerTravel().net.y
        }
        let down = mean { seed in
            let rig = pinched(seed: seed)
            rig.twist(by: 0.6 * c.downRange, over: 0.4)
            rig.hold(0.2)
            return rig.pointerTravel().net.y
        }
        XCTAssertGreaterThan(up, 100)
        XCTAssertEqual(up, down, accuracy: 0.2 * down, "up \(up), down \(down)")
    }

    private func mean(_ travel: (UInt64) -> Double) -> Double {
        (UInt64(1)...8).map(travel).reduce(0, +) / 8
    }

    /// A pinch that lands mid-roll, palm partly up, and rolls back to rest is
    /// moving back across the palm-up range: it moves as far as the roll out,
    /// not 2.6 times as far on the palm-down scale.
    func testAPinchStartedMidRollScalesByTheHandsNeutral() {
        let c = ForearmTwistConfig()
        let away = mean { seed in
            let rig = pinched(seed: seed)
            rig.twist(by: -0.5 * c.upRange, over: 0.4)
            rig.hold(0.2)
            return -rig.pointerTravel().net.y
        }
        let back = mean { seed in
            let rig = Rig(seed: seed)
            rig.hold(2)
            rig.twist(by: -0.5 * c.upRange, over: 0.4)
            rig.pinch(true, over: 0.08)
            rig.hold(0.1)
            rig.clearOutputs()
            rig.twist(by: 1 / (1 - 0.5 * c.upRange) - 1, over: 0.4)
            rig.hold(0.2)
            return rig.pointerTravel().net.y
        }
        XCTAssertGreaterThan(away, 100)
        XCTAssertEqual(back, away, accuracy: 0.3 * away, "out \(away), back \(back)")
    }

    func testStillHandDoesNotDrift() {
        for seed in UInt64(1)...6 {
            let rig = pinched(seed: seed, webcam: true)
            rig.hold(5)
            XCTAssertLessThan(rig.pointerTravel().path / 5, 1, "seed \(seed), points per second")
        }
    }

    /// Held still, the width creeps about 7 % over a few seconds; the neutral
    /// follows it, so it moves nothing.
    func testSlowCreepDoesNotDrift() {
        for seed in UInt64(1)...3 {
            let rig = pinched(seed: seed, webcam: true)
            rig.twist(by: -0.07, over: 4)
            rig.twist(by: 0.07, over: 4)
            XCTAssertLessThan(rig.pointerTravel().path / 8, 1, "seed \(seed), points per second")
        }
    }

    func testNeutralFollowsTheResting() {
        var twist = ForearmTwist()
        var gen = SyntheticHand(sigma: 0)
        var pose = HandPose()
        var t = 0.0
        for _ in 0..<60 { t += 1.0 / 30; _ = twist.update(gen.sample(pose), at: t) }
        XCTAssertEqual(twist.neutral!, 0.6, accuracy: 0.01)
        pose.palmWidth = 0.9
        for _ in 0..<300 { t += 1.0 / 30; _ = twist.update(gen.sample(pose), at: t) }
        XCTAssertEqual(twist.neutral!, 0.54, accuracy: 0.01, "rests rolled: that is the neutral now")
    }

    func testRollingWithoutAPinchMovesNothing() {
        let rig = Rig()
        rig.hold(2)
        for _ in 0..<3 {
            rig.twist(by: -0.3, over: 0.4)
            rig.twist(by: 0.3 / 0.7, over: 0.4)
        }
        XCTAssertEqual(rig.pointerTravel().path, 0)
        XCTAssertTrue(rig.flings.isEmpty)
    }

    /// The roll's vertical motion is kept apart from the hand's: moving the
    /// hand sideways moves the pointer exactly as without the roll channel.
    func testHorizontalMotionIsUnchanged() {
        func sideways(_ gain: Double) -> Vec2 {
            let rig = Rig()
            rig.engine.twist.config.gain = gain
            rig.hold(2)
            rig.pinch(true, over: 0.08)
            rig.hold(0.3)
            rig.clearOutputs()
            rig.run(0.6) { p, pose in
                pose.palm.x = 0.8 + 0.8 * hu * minimumJerk(p)
                pose.palmWidth = 1 - 0.25 * sin(p * .pi)
            }
            rig.hold(0.2)
            return rig.pointerTravel().net
        }
        let with = sideways(ForearmTwistConfig().gain), without = sideways(0)
        XCTAssertEqual(with.x, without.x, accuracy: 1e-9)
        XCTAssertGreaterThan(with.x, 100)
    }

    func testTranslationCountsHalf() {
        let rig = pinched()
        rig.move(by: Vec2(0, 0.6 * hu), over: 0.5)
        rig.hold(0.2)
        let down = rig.pointerTravel().net.y

        let side = pinched()
        side.move(by: Vec2(0.6 * hu, 0), over: 0.5)
        side.hold(0.2)
        XCTAssertEqual(down / side.pointerTravel().net.x, ForearmTwistConfig().translationWeight, accuracy: 0.05)
    }
}

private let hu = HandPose().size

/// A roll can hide the tips from each other for a few frames; the pinch holds
/// through it without clicking or sticking.
final class RollHoldTests: XCTestCase {
    /// Rolls palm up and back, a quarter of the width each way and 0.8 s a
    /// cycle, the tips reading apart from `apartAfter` on.
    private func rollWithTipsApart(_ rig: Rig, for duration: Double, apartAfter: Double = 0.15,
                                   _ also: @escaping (Double, inout HandPose) -> Void = { _, _ in }) {
        let from = rig.pose.palmWidth
        rig.run(duration) { p, pose in
            let t = p * duration
            pose.palmWidth = from * (1 - 0.25 * sin(2 * .pi * t / 0.8))
            pose.pinchRatio = t < apartAfter ? Rig.touching : 0.3
            also(p, &pose)
        }
    }

    func testAPinchHoldsThroughARoll() {
        let rig = Rig()
        rig.hold(2)
        rig.pinch(true, over: 0.08)
        rig.hold(0.3)
        rig.clearOutputs()
        rollWithTipsApart(rig, for: 0.3)
        rig.pinch(true, over: 0.05)
        rig.hold(0.2)
        XCTAssertEqual(rig.count(.touchEnded), 0)
        XCTAssertLessThan(rig.pointerTravel().net.y, -20, "the roll kept moving the pointer")
        rig.pinch(false)
        rig.hold(0.3)
        XCTAssertEqual(rig.count(.touchEnded), 1)
        XCTAssertTrue(rig.clicks.isEmpty)
    }

    func testAHoldOutlastingItsTimeoutEndsWithoutAClick() {
        let rig = Rig()
        rig.hold(2)
        rig.pinch(true, over: 0.08)
        rig.hold(0.05)
        rollWithTipsApart(rig, for: 1.0)
        XCTAssertEqual(rig.count(.touchEnded), 1, "not stuck")
        let ended = rig.outputs.first { $0.output == .touchEnded }!.t
        let parted = rig.outputs.first!.t
        XCTAssertLessThan(ended - parted, 0.3 + TouchThresholds().rollHold + 0.1)
        rig.hold(0.5)
        XCTAssertTrue(rig.clicks.isEmpty)
        XCTAssertFalse(rig.engine.snapshot.isTouching)
    }

    func testOnlyTheRollMovesWhileTheTipsReadApart() {
        let rig = Rig()
        rig.hold(2)
        rig.pinch(true, over: 0.08)
        rig.hold(0.3)
        rig.clearOutputs()
        let from = rig.pose.palm
        rollWithTipsApart(rig, for: 0.3) { p, pose in pose.palm = from + Vec2(0.4 * hu * p, 0) }
        let heldAt = rig.t
        XCTAssertTrue(rig.engine.snapshot.isTouching)
        XCTAssertLessThan(abs(rig.pointerTravel(since: heldAt - 0.14).net.x), 5, "the hand's own motion waits for the tips")
    }

    func testTipsPartingWithoutARollReleaseAsBefore() {
        let rig = Rig()
        rig.hold(2)
        rig.pinch(true, over: 0.08)
        rig.hold(0.05)
        rig.pinch(false)
        rig.hold(0.3)
        XCTAssertEqual(rig.clicks, [1])
    }
}
