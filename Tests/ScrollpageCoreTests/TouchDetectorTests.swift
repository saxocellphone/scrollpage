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
        XCTAssertEqual(detector.pose(tips(ti: 0.026)), .pinch)
        XCTAssertEqual(detector.pose(tips(ti: 0.08)), .pinch, "a calibrated touch reads up to ~0.10")
        XCTAssertNil(detector.pose(tips(ti: 0.081)))
        XCTAssertNil(detector.pose(tips(ti: 0.10)), "the tightest calibrated hover (median)")
        XCTAssertNil(detector.pose(tips(ti: 0.8)), "open hand")
        XCTAssertEqual(detector.pose(tips(ti: 0.03, tm: 0.18, im: 0.4)), .pinch)
        XCTAssertEqual(detector.pose(tips(ti: 0.03, tm: 0.4, im: 0.18)), .pinch)
        XCTAssertNil(detector.pose(tips(ti: 0.03, tm: 0.179, im: 0.4)), "middle tip too close for a plain pinch")
    }

    func testThreeFingerLimitsArePerPair() {
        XCTAssertEqual(detector.pose(tips(ti: 0.03, tm: 0.05, im: 0.04)), .threeFinger)
        XCTAssertEqual(detector.pose(tips(ti: 0.12, tm: 0.18, im: 0.26)), .threeFinger, "every pair at its limit")
        XCTAssertEqual(detector.pose(tips(ti: 0.18, tm: 0.12, im: 0.26)), .threeFinger)
        XCTAssertNil(detector.pose(tips(ti: 0.12, tm: 0.181, im: 0.2)), "thumb–middle")
        XCTAssertNil(detector.pose(tips(ti: 0.181, tm: 0.1, im: 0.2)), "thumb–index")
        XCTAssertNil(detector.pose(tips(ti: 0.1, tm: 0.1, im: 0.261)), "index–middle")
    }

    /// Medians of the three-finger step in the two calibration runs: index and
    /// middle tips sit a fingertip apart on the thumb, wider than the old
    /// single 0.12 limit allowed.
    func testCalibratedThreeFingerPosesCount() {
        XCTAssertEqual(detector.pose(tips(ti: 0.094, tm: 0.112, im: 0.198)), .threeFinger)
        XCTAssertEqual(detector.pose(tips(ti: 0.066, tm: 0.119, im: 0.155)), .threeFinger)
        XCTAssertEqual(detector.pose(tips(ti: 0.168, tm: 0.113, im: 0.219)), .threeFinger,
                       "run 1: thumb–index and index–middle at their 90th percentile, the thumb's nearer tip at its 95th")
    }

    /// A hand closing between pinches, index and middle side by side, keeps
    /// the thumb about 0.14 from both: within the pair limits, but not touching.
    func testThreeFingerNeedsTheThumbTouchingOne() {
        XCTAssertNil(detector.pose(tips(ti: 0.153, tm: 0.151, im: 0.052)))
        XCTAssertNil(detector.pose(tips(ti: 0.178, tm: 0.174, im: 0.063)))
        XCTAssertNil(detector.pose(tips(ti: 0.121, tm: 0.13, im: 0.1)))
        XCTAssertEqual(detector.pose(tips(ti: 0.12, tm: 0.13, im: 0.1)), .threeFinger)
        XCTAssertEqual(detector.pose(tips(ti: 0.16, tm: 0.12, im: 0.1)), .threeFinger)
    }

    /// The plain pinch's middle-apart floor is the three-finger thumb–middle
    /// ceiling, so the two poses never overlap: across the plane of middle-tip
    /// distances, a touching thumb and index give exactly one of them or neither.
    func testPinchAndThreeFingerNeverOverlap() {
        let t = TouchThresholds()
        XCTAssertGreaterThanOrEqual(t.middleApart, t.threeEnter.thumb)
        XCTAssertLessThan(t.pinchEnter, t.pinchExit)
        XCTAssertLessThan(t.threeEnter.thumb, t.threeExit.thumb)
        XCTAssertLessThan(t.threeEnter.indexMiddle, t.threeExit.indexMiddle)
        XCTAssertLessThanOrEqual(t.threeEnter.thumb, t.threeMoveMax.thumb)
        XCTAssertLessThanOrEqual(t.threeMoveMax.indexMiddle, t.threeExit.indexMiddle)
        for ti in stride(from: 0.0, through: 0.08, by: 0.02) {
            for tm in stride(from: 0.1, through: 0.4, by: 0.01) {
                for im in stride(from: 0.1, through: 0.4, by: 0.01) {
                    let m = tips(ti: ti, tm: tm, im: im)
                    let three = m.threeWithin(t.threeEnter) == true
                    let pinch = min(tm, im) >= t.middleApart
                    XCTAssertFalse(three && pinch && tm != t.threeEnter.thumb, "\(ti) \(tm) \(im)")
                    XCTAssertEqual(detector.pose(m), three ? .threeFinger : pinch ? .pinch : nil, "\(ti) \(tm) \(im)")
                }
            }
        }
    }

    func testPinchNeedsTheOtherThreeFingersExtended() {
        XCTAssertEqual(detector.pose(tips(ti: 0.03, extended: [.middle, .ring, .little])), .pinch)
        XCTAssertNil(detector.pose(tips(ti: 0.03, extended: [.middle])), "ring and little curled")
        XCTAssertNil(detector.pose(tips(ti: 0.03, extended: [.ring, .little])), "middle curled")
        XCTAssertNil(detector.pose(tips(ti: 0.03, extended: [])), "fist")
    }

    func testThreeFingerNeedsRingAndLittleExtended() {
        XCTAssertEqual(detector.pose(tips(ti: 0.03, tm: 0.04, im: 0.04, extended: [.ring, .little])), .threeFinger)
        XCTAssertNil(detector.pose(tips(ti: 0.03, tm: 0.04, im: 0.04, extended: [.ring])))
        XCTAssertNil(detector.pose(tips(ti: 0.03, tm: 0.04, im: 0.04, extended: [])))
    }

    func testUnreadableFramesNeverTouch() {
        XCTAssertNil(detector.pose(tips(ti: 0.03, readable: false)))
        XCTAssertNil(detector.pose(tips(ti: 0.03, middleReadable: false)), "can't tell a pinch from three fingers")
        XCTAssertNil(detector.pose(tips(ti: 0.03, tm: 0.03, im: 0.03, middleReadable: false)))
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
        // Half hidden behind the thumb in the three-finger pose, the middle tip
        // read 0.37 median in calibration.
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
        XCTAssertEqual(detector.pending, .pinch)
        XCTAssertTrue(detector.isEngaged)
        XCTAssertEqual(frame(ti: 0.03), .began(.pinch))
        XCTAssertEqual(detector.active, .pinch)
    }

    func testTouchMustStartFromFingersApart() {
        XCTAssertEqual(frames(30, ti: 0.03), [], "a hand arriving already pinched")
        frames(2, ti: 0.8)
        XCTAssertEqual(frames(3, ti: 0.03), [.began(.pinch)])
    }

    func testHysteresisHoldsATouchAndOnlyFirmContactMoves() {
        frames(3, ti: 0.8)
        frames(3, ti: 0.03)
        frame(ti: 0.095)
        XCTAssertTrue(detector.canMove, "a held touch in calibration reads up to ~0.10")
        frame(ti: 0.11)
        XCTAssertFalse(detector.canMove, "parting fingers don't move the pointer")
        XCTAssertEqual(detector.active, .pinch)
        XCTAssertNil(frame(ti: 0.13), "one frame apart does not release")
        XCTAssertNil(frame(ti: 0.12), "still inside")
        XCTAssertNil(frame(ti: 0.13))
        XCTAssertEqual(frame(ti: 0.13), .ended(.pinch, lifted: true))
        XCTAssertFalse(detector.canMove)
    }

    func testNoisyFramesDuringConfirmationNeitherCountNorRestart() {
        frames(3, ti: 0.8)
        frames(2, ti: 0.03)
        XCTAssertNil(frame(ti: 0.10))
        XCTAssertNil(frame(ti: 0.11))
        XCTAssertEqual(detector.pending, .pinch)
        XCTAssertEqual(frame(ti: 0.03), .began(.pinch))

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
        XCTAssertNil(other.pending)
        _ = step(0.03); _ = step(0.03)
        XCTAssertEqual(step(0.03), .began(.pinch))
    }

    func testTooManyNoisyFramesRestartConfirmation() {
        frames(3, ti: 0.8)
        frame(ti: 0.03)
        frames(2, ti: 0.10)
        frame(ti: 0.03)
        XCTAssertEqual(detector.pending, .pinch)
        XCTAssertNil(frame(ti: 0.10), "a third noisy frame")
        XCTAssertNil(detector.pending)
        XCTAssertEqual(frames(2, ti: 0.03), [])
        XCTAssertEqual(frame(ti: 0.03), .began(.pinch))
    }

    /// Run 2's hover a hair apart: 0.10 median, brushing 0.076 now and then.
    /// Inside the 0.12 release, those frames would add up to a touch if
    /// confirmation forgave any number of misses in between.
    func testAHoverThatBrushesTheThresholdNeverTouches() {
        frames(3, ti: 0.8)
        for _ in 0..<20 {
            XCTAssertEqual(frames(1, ti: 0.076) + frames(3, ti: 0.10), [])
        }
        XCTAssertNil(detector.active)
    }

    func testHoveringJustApartNeverTouches() {
        frames(3, ti: 0.8)
        for ti in stride(from: 0.085, through: 0.3, by: 0.005) {
            XCTAssertEqual(frames(10, ti: ti), [], "ti \(ti)")
            XCTAssertNil(detector.pending)
        }
    }

    /// Letting go is seeing the fingers apart, even when the next frame is
    /// back inside the release: a near-touch that let go doesn't swallow the
    /// real touch right after it.
    func testTheFrameATouchLetsGoArmsTheNext() {
        frames(3, ti: 0.8)
        frames(3, ti: 0.03)
        XCTAssertEqual(frames(2, ti: 0.15), [.ended(.pinch, lifted: true)])
        frame(ti: 0.11)
        XCTAssertEqual(frames(3, ti: 0.03), [.began(.pinch)])
    }

    func testUnreadableFramesHoldBrieflyThenEndWithoutLifting() {
        frames(3, ti: 0.8)
        frames(3, ti: 0.03)
        XCTAssertEqual(frames(5, ti: 0.03, hidden: [.thumbTip]), [], "0.17 s is within the grace")
        XCTAssertEqual(detector.active, .pinch)
        XCTAssertEqual(frames(3, ti: 0.03), [])
        XCTAssertEqual(frames(8, ti: 0.03, hidden: [.indexTip]), [.ended(.pinch, lifted: false)])
        XCTAssertNil(detector.active)
        XCTAssertEqual(frames(10, ti: 0.03), [], "a pinch doesn't resume: letting go would click")
    }

    func testAThreeFingerTouchResumesAfterTheMiddleTipDropsOut() {
        frames(3, ti: 0.8)
        XCTAssertEqual(frames(3, ti: 0.05, middle: 0.05), [.began(.threeFinger)])
        XCTAssertEqual(frames(8, ti: 0.05, middle: 0.05, hidden: [.middleTip]), [.ended(.threeFinger, lifted: false)])
        XCTAssertEqual(frames(3, ti: 0.05, middle: 0.05), [.began(.threeFinger)], "thumb and index never parted")
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
        XCTAssertEqual(frame(ti: 0.03), .began(.pinch))
    }

    func testThreeFingerBeginsAndEndsWhenTheMiddleParts() {
        frames(3, ti: 0.8)
        XCTAssertEqual(frames(3, ti: 0.03, middle: 0.03), [.began(.threeFinger)])
        XCTAssertEqual(frames(10, ti: 0.04, middle: 0.06), [])
        XCTAssertTrue(detector.canMove)
        XCTAssertEqual(frames(2, ti: 0.03), [.ended(.threeFinger, lifted: true)])
        XCTAssertEqual(frames(10, ti: 0.03), [], "the pinch left behind needs the fingers apart first")
        frames(2, ti: 0.8)
        XCTAssertEqual(frames(3, ti: 0.03), [.began(.pinch)])
    }

    func testPinchStaysAPinchWhenTheMiddleJoins() {
        frames(3, ti: 0.8)
        frames(3, ti: 0.03)
        XCTAssertEqual(frames(20, ti: 0.03, middle: 0.03), [])
        XCTAssertEqual(detector.active, .pinch)
        XCTAssertTrue(detector.canMove)
    }

    func testFingersSeenApartSurviveAShortLoss() {
        frames(3, ti: 0.8)
        detector.handLost(at: t)
        t += 0.3
        XCTAssertEqual(frames(3, ti: 0.03), [.began(.pinch)], "back within 0.5 s, already touching")

        frames(3, ti: 0.8)
        frames(3, ti: 0.03)
        detector.handLost(at: t)
        XCTAssertNil(detector.active)
        t += 1.0
        XCTAssertEqual(frames(10, ti: 0.03), [], "back after a long absence: a fresh hand")
    }

    /// The middle tip within 0.18 of the thumb makes three fingers; beyond it,
    /// trailing an extended middle finger (0.18 to 0.22 in quick pinches on
    /// the webcam), the touch is a pinch.
    func testTheMiddleTipDecidesBetweenPinchAndThreeFinger() {
        frames(3, ti: 0.8)
        XCTAssertEqual(frames(3, ti: 0.03, middle: 0.17), [.began(.threeFinger)])
        XCTAssertEqual(frames(2, ti: 0.8), [.ended(.threeFinger, lifted: true)])
        XCTAssertEqual(frames(3, ti: 0.03, middle: 0.19), [.began(.pinch)])
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

    func testNearThreeFingerHandNeverScrolls() {
        for seed in UInt64(1)...4 {
            let rig = Rig.webcam(seed: seed, fps: 30)
            var noise = NoiseSource(seed: seed &+ 7)
            let home = rig.pose.palm
            rig.hold(0.5)
            rig.run(10) { p, pose in
                pose.pinchRatio = 0.14 + abs(noise.gaussian(0.02))
                pose.middleTouch = 0.16 + abs(noise.gaussian(0.02))
                pose.palm = home + Vec2(0, sin(p * 2 * .pi * 5) * 0.5 * pose.size)
            }
            XCTAssertTrue(rig.scrolls.isEmpty, "seed \(seed)")
            XCTAssertEqual(rig.count(.scrollBegan), 0, "seed \(seed)")
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
