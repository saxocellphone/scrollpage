import XCTest
@testable import ScrollpageCore

private func tips(ti: Double, tm: Double = 0.5, im: Double = 0.5,
                     readable: Bool = true, middleReadable: Bool = true,
                     extended: Set<Finger> = [.middle, .ring, .little]) -> TouchMeasure {
    TouchMeasure(thumbIndex: ti, thumbMiddle: tm, indexMiddle: im, readable: readable,
                 middleReadable: readable && middleReadable, extended: extended)
}

final class TouchClassifierTests: XCTestCase {
    private let detector = TouchDetector()

    func testPinchNeedsTipsTouchingAndTheMiddleFingerApart() {
        XCTAssertTrue(detector.isPinch(tips(ti: 0.026)))
        XCTAssertTrue(detector.isPinch(tips(ti: 0.08)), "a calibrated touch reads up to ~0.10")
        XCTAssertFalse(detector.isPinch(tips(ti: 0.081)))
        XCTAssertFalse(detector.isPinch(tips(ti: 0.10)), "the tightest calibrated hover (median)")
        XCTAssertFalse(detector.isPinch(tips(ti: 0.8)), "open hand")
        XCTAssertTrue(detector.isPinch(tips(ti: 0.03, tm: 0.18, im: 0.4)))
        XCTAssertTrue(detector.isPinch(tips(ti: 0.03, tm: 0.4, im: 0.18)))
        XCTAssertFalse(detector.isPinch(tips(ti: 0.03, tm: 0.179, im: 0.4)), "middle tip too close for the OK sign")
    }

    func testPinchNeedsTheOtherThreeFingersExtended() {
        XCTAssertTrue(detector.isPinch(tips(ti: 0.03, extended: [.middle, .ring, .little])))
        XCTAssertFalse(detector.isPinch(tips(ti: 0.03, extended: [.middle])), "ring and little curled")
        XCTAssertFalse(detector.isPinch(tips(ti: 0.03, extended: [.ring, .little])), "middle curled")
        XCTAssertFalse(detector.isPinch(tips(ti: 0.03, extended: [])), "fist")
    }

    func testUnreadableFramesNeverTouch() {
        XCTAssertFalse(detector.isPinch(tips(ti: 0.03, readable: false)))
        XCTAssertFalse(detector.isPinch(tips(ti: 0.03, middleReadable: false)), "can't see the middle finger stand clear")
    }

    func testMeasureRejectsLowConfidenceTips() {
        var gen = SyntheticHand(sigma: 0, touchSigma: 0)
        var pose = HandPose()
        pose.pinchRatio = 0.03
        let size = pose.size
        XCTAssertTrue(TouchMeasure(gen.sample(pose), handSize: size).middleReadable)
        for joint in [HandJoint.thumbTip, .indexTip] {
            var hand = gen.sample(pose)
            hand[joint]?.confidence = 0.4
            XCTAssertTrue(TouchMeasure(hand, handSize: size).readable, "\(joint)")
            hand[joint]?.confidence = 0.39
            XCTAssertFalse(TouchMeasure(hand, handSize: size).readable, "\(joint)")
        }
        // Half hidden behind the thumb, the middle tip read 0.37 median in calibration.
        var hand = gen.sample(pose)
        hand[.middleTip]?.confidence = 0.3
        XCTAssertTrue(TouchMeasure(hand, handSize: size).middleReadable)
        hand[.middleTip]?.confidence = 0.29
        let m = TouchMeasure(hand, handSize: size)
        XCTAssertTrue(m.readable)
        XCTAssertFalse(m.middleReadable)
    }
}

final class TouchDetectorTests: XCTestCase {
    private var gen = SyntheticHand(sigma: 0, touchSigma: 0)
    private var detector = TouchDetector()
    private var pose = HandPose()
    private var t = 0.0

    @discardableResult
    private func frame(ti: Double, middle: Double? = nil, hidden: Set<HandJoint> = []) -> TouchEvent? {
        t += 1.0 / 30
        pose.pinchRatio = ti
        pose.middleTouch = middle
        pose.hidden = hidden
        return detector.update(gen.sample(pose), handSize: pose.size, at: t)
    }

    @discardableResult
    private func frames(_ n: Int, ti: Double, middle: Double? = nil, hidden: Set<HandJoint> = []) -> [TouchEvent] {
        (0..<n).compactMap { _ in frame(ti: ti, middle: middle, hidden: hidden) }
    }

    func testPinchBeginsOnTheThirdTouchingFrame() {
        frames(3, ti: 0.8)
        XCTAssertNil(frame(ti: 0.03))
        XCTAssertNil(frame(ti: 0.03))
        XCTAssertTrue(detector.pending)
        XCTAssertTrue(detector.isEngaged)
        XCTAssertEqual(frame(ti: 0.03), .began)
        XCTAssertTrue(detector.active)
    }

    func testTouchMustStartFromFingersApart() {
        XCTAssertEqual(frames(30, ti: 0.03), [], "a hand arriving already pinched")
        frames(2, ti: 0.8)
        XCTAssertEqual(frames(3, ti: 0.03), [.began])
    }

    func testHysteresisHoldsATouchAndOnlyFirmContactMoves() {
        frames(3, ti: 0.8)
        frames(3, ti: 0.03)
        frame(ti: 0.095)
        XCTAssertTrue(detector.canMove, "a held touch in calibration reads up to ~0.10")
        frame(ti: 0.11)
        XCTAssertFalse(detector.canMove, "parting fingers don't move the pointer")
        XCTAssertTrue(detector.active)
        XCTAssertNil(frame(ti: 0.13), "one frame apart does not release")
        XCTAssertNil(frame(ti: 0.12), "still inside")
        XCTAssertNil(frame(ti: 0.13))
        XCTAssertEqual(frame(ti: 0.13), .ended(lifted: true))
        XCTAssertFalse(detector.canMove)
    }

    func testNoisyFramesDuringConfirmationNeitherCountNorRestart() {
        frames(3, ti: 0.8)
        frames(2, ti: 0.03)
        XCTAssertNil(frame(ti: 0.10))
        XCTAssertNil(frame(ti: 0.11))
        XCTAssertTrue(detector.pending)
        XCTAssertEqual(frame(ti: 0.03), .began)

        var other = TouchDetector()
        var t = 0.0
        func step(_ ti: Double) -> TouchEvent? {
            t += 1.0 / 30
            pose.pinchRatio = ti
            pose.middleTouch = nil
            return other.update(gen.sample(pose), handSize: pose.size, at: t)
        }
        _ = step(0.8)
        _ = step(0.03); _ = step(0.03)
        XCTAssertNil(step(0.13), "leaving the exit threshold starts over")
        XCTAssertFalse(other.pending)
        _ = step(0.03); _ = step(0.03)
        XCTAssertEqual(step(0.03), .began)
    }

    func testTooManyNoisyFramesRestartConfirmation() {
        frames(3, ti: 0.8)
        frame(ti: 0.03)
        frames(2, ti: 0.10)
        frame(ti: 0.03)
        XCTAssertTrue(detector.pending)
        XCTAssertNil(frame(ti: 0.10), "a third noisy frame")
        XCTAssertFalse(detector.pending)
        XCTAssertEqual(frames(2, ti: 0.03), [])
        XCTAssertEqual(frame(ti: 0.03), .began)
    }

    /// Run 2's hover a hair apart: 0.10 median, brushing 0.076 now and then.
    /// Inside the 0.12 release, those frames would add up to a touch if
    /// confirmation forgave any number of misses in between.
    func testAHoverThatBrushesTheThresholdNeverTouches() {
        frames(3, ti: 0.8)
        for _ in 0..<20 {
            XCTAssertEqual(frames(1, ti: 0.076) + frames(3, ti: 0.10), [])
        }
        XCTAssertFalse(detector.active)
    }

    func testHoveringJustApartNeverTouches() {
        frames(3, ti: 0.8)
        for ti in stride(from: 0.085, through: 0.3, by: 0.005) {
            XCTAssertEqual(frames(10, ti: ti), [], "ti \(ti)")
            XCTAssertFalse(detector.pending)
        }
    }

    /// Letting go is seeing the fingers apart, even when the next frame is
    /// back inside the release: a near-touch that let go doesn't swallow the
    /// real touch right after it.
    func testTheFrameATouchLetsGoArmsTheNext() {
        frames(3, ti: 0.8)
        frames(3, ti: 0.03)
        XCTAssertEqual(frames(2, ti: 0.15), [.ended(lifted: true)])
        frame(ti: 0.11)
        XCTAssertEqual(frames(3, ti: 0.03), [.began])
    }

    func testUnreadableFramesHoldBrieflyThenEndWithoutLifting() {
        frames(3, ti: 0.8)
        frames(3, ti: 0.03)
        XCTAssertEqual(frames(5, ti: 0.03, hidden: [.thumbTip]), [], "0.17 s is within the grace")
        XCTAssertTrue(detector.active)
        XCTAssertEqual(frames(3, ti: 0.03), [])
        XCTAssertEqual(frames(8, ti: 0.03, hidden: [.indexTip]), [.ended(lifted: false)])
        XCTAssertFalse(detector.active)
        XCTAssertEqual(frames(10, ti: 0.03), [], "a pinch doesn't resume: letting go would click")
    }

    func testUnreadableFramesCantConfirmATouch() {
        frames(3, ti: 0.8)
        XCTAssertEqual(frames(10, ti: 0.03, hidden: [.thumbTip]), [])
        XCTAssertEqual(frames(10, ti: 0.03, hidden: [.middleTip]), [])
        frames(2, ti: 0.03, hidden: [.thumbTip])
        frame(ti: 0.03)
        frame(ti: 0.03)
        XCTAssertNil(frame(ti: 0.03, hidden: [.thumbTip]), "an unreadable frame restarts the count")
        frames(2, ti: 0.03)
        XCTAssertEqual(frame(ti: 0.03), .began)
    }

    func testPinchStaysAPinchWhenTheMiddleJoins() {
        frames(3, ti: 0.8)
        frames(3, ti: 0.03)
        XCTAssertEqual(frames(20, ti: 0.03, middle: 0.03), [])
        XCTAssertTrue(detector.active)
        XCTAssertTrue(detector.canMove)
    }

    func testFingersSeenApartSurviveAShortLoss() {
        frames(3, ti: 0.8)
        detector.handLost(at: t)
        t += 0.3
        XCTAssertEqual(frames(3, ti: 0.03), [.began], "back within 0.5 s, already touching")

        frames(3, ti: 0.8)
        frames(3, ti: 0.03)
        detector.handLost(at: t)
        XCTAssertFalse(detector.active)
        t += 1.0
        XCTAssertEqual(frames(10, ti: 0.03), [], "back after a long absence: a fresh hand")
    }

    /// A middle tip within 0.18 of the thumb and index tips isn't the OK sign;
    /// beyond it (trailing an extended middle finger, 0.18 to 0.22 in quick
    /// pinches on the webcam) the touch is a pinch.
    func testTheMiddleTipMustStandClear() {
        frames(3, ti: 0.8)
        XCTAssertEqual(frames(6, ti: 0.03, middle: 0.17), [])
        XCTAssertEqual(frames(3, ti: 0.03, middle: 0.19), [.began])
    }

    // MARK: Rolling

    @discardableResult
    private func rollFrames(_ n: Int, ti: Double, rolling: Bool = true) -> [TouchEvent] {
        (0..<n).compactMap { _ in
            t += 1.0 / 30
            pose.pinchRatio = ti
            pose.middleTouch = nil
            return detector.update(gen.sample(pose), handSize: pose.size, rolling: rolling, at: t)
        }
    }

    /// Rolling the palm down and back opens the tips to 0.25–0.37 on the
    /// webcam for a few frames while they still touch.
    func testARollHoldsThePinchWhileTheTipsReadApart() {
        frames(3, ti: 0.8)
        XCTAssertEqual(rollFrames(3, ti: 0.03), [.began])
        XCTAssertEqual(rollFrames(6, ti: 0.3), [], "0.2 s apart while rolling")
        XCTAssertTrue(detector.active)
        XCTAssertTrue(detector.heldThroughRoll)
        XCTAssertTrue(detector.canMove, "the roll keeps moving the pointer")
        XCTAssertEqual(rollFrames(10, ti: 0.03), [])
        XCTAssertTrue(detector.active)
        XCTAssertFalse(detector.heldThroughRoll)
    }

    func testARollHoldTimesOutWithoutAClick() {
        frames(3, ti: 0.8)
        rollFrames(3, ti: 0.03)
        var ended: Double?
        let start = t
        for _ in 0..<40 where ended == nil {
            if rollFrames(1, ti: 0.3) == [.ended(lifted: false)] { ended = t }
        }
        let held = try! XCTUnwrap(ended) - start
        XCTAssertLessThanOrEqual(held, TouchThresholds().rollHold + 2.0 / 30 + 1e-9, "from the last frame touching")
        XCTAssertLessThanOrEqual(TouchThresholds().rollHold, 0.6)
        XCTAssertFalse(detector.active)
        XCTAssertFalse(detector.heldThroughRoll)
    }

    func testTipsThatPartWhenTheRollHasStoppedReleaseAsUsual() {
        frames(3, ti: 0.8)
        rollFrames(3, ti: 0.03)
        XCTAssertEqual(frames(2, ti: 0.3), [.ended(lifted: true)])
    }

    /// Opening the hand spreads the knuckles, which reads as a roll: a roll
    /// that only starts once the tips have parted holds nothing.
    func testARollThatStartsAfterTheTipsPartDoesntHold() {
        frames(3, ti: 0.8)
        frames(3, ti: 0.03)
        XCTAssertEqual(frames(1, ti: 0.3), [])
        XCTAssertEqual(rollFrames(1, ti: 0.3), [.ended(lifted: true)])
    }

    func testTipsWideApartReleaseEvenWhileRolling() {
        frames(3, ti: 0.8)
        rollFrames(3, ti: 0.03)
        XCTAssertEqual(rollFrames(2, ti: 0.45), [.ended(lifted: true)], "a real release passes 0.4")
    }

    func testAHeldRollThatEndsApartDoesntClick() {
        frames(3, ti: 0.8)
        rollFrames(3, ti: 0.03)
        XCTAssertEqual(rollFrames(2, ti: 0.3), [])
        XCTAssertEqual(rollFrames(1, ti: 0.3, rolling: false), [.ended(lifted: false)],
                       "a roll that let go is not a tap")
    }
}

/// The guarantee behind touch-only control: a hand hovering just short of a
/// touch, as measured on the webcam, never moves the pointer.
final class NearTouchTests: XCTestCase {
    func testNoisyNearTouchHandNeverMovesThePointer() {
        for seed in UInt64(1)...6 {
            let rig = Rig.webcam(seed: seed, fps: 30)
            var noise = NoiseSource(seed: seed &+ 99)
            let home = rig.pose.palm
            let u = rig.pose.size
            var ratio = 0.19
            rig.hold(0.5)
            rig.run(20) { p, pose in
                // A random walk over the measured hovering band (10th to 90th
                // percentile 0.13 to 0.26), with the hand roaming as if pointing.
                ratio = min(0.28, max(0.12, ratio + noise.gaussian(0.01)))
                pose.pinchRatio = ratio
                let a = p * 2 * .pi * 7
                pose.palm = home + Vec2(cos(a), sin(1.3 * a)) * (0.8 * u)
            }
            XCTAssertEqual(rig.pointerTravel().path, 0, "seed \(seed)")
            XCTAssertEqual(rig.count(.touchBegan), 0, "seed \(seed)")
            XCTAssertEqual(rig.count(.scrollBegan), 0, "seed \(seed)")
            XCTAssertTrue(rig.clicks.isEmpty, "seed \(seed)")
        }
    }

    /// The tightest hover in calibration: thumb and index a hair apart, 0.10
    /// median, 0.08 at the 5th percentile. At the calibration's hand size the
    /// webcam joint noise alone gives that spread.
    func testTightHoverNeverTouches() {
        for seed in UInt64(1)...6 {
            let rig = Rig.webcam(seed: seed, fps: 30)
            rig.pose.size = 0.18
            var noise = NoiseSource(seed: seed &+ 31)
            var ratio = 0.10
            rig.hold(0.5)
            rig.run(20) { _, pose in
                ratio = min(0.105, max(0.095, ratio + noise.gaussian(0.002)))
                pose.pinchRatio = ratio
            }
            XCTAssertEqual(rig.count(.touchBegan), 0, "seed \(seed)")
            XCTAssertTrue(rig.clicks.isEmpty, "seed \(seed)")
            XCTAssertEqual(rig.pointerTravel().path, 0, "seed \(seed)")
        }
    }

    func testHiddenFingertipsMidPinchEndWithoutAClick() {
        let rig = Rig()
        rig.hold(0.5)
        rig.pinch(true)
        rig.hold(0.05)
        rig.pose.hidden = [.thumbTip, .indexTip]
        rig.hold(0.4)
        XCTAssertEqual(rig.count(.touchEnded), 1)
        rig.pose.hidden = []
        rig.pinch(false)
        rig.hold(0.3)
        XCTAssertTrue(rig.clicks.isEmpty)
        XCTAssertEqual(rig.pointerTravel().path, 0)
    }

    func testBrieflyHiddenFingertipsDontInterruptATap() {
        let rig = Rig()
        rig.hold(0.5)
        rig.pinch(true)
        rig.hold(0.05)
        rig.pose.hidden = [.thumbTip]
        rig.hold(0.1)
        rig.pose.hidden = []
        rig.pinch(false)
        rig.hold(0.3)
        XCTAssertEqual(rig.clicks, [1])
        XCTAssertEqual(rig.count(.touchBegan), 1)
    }
}
