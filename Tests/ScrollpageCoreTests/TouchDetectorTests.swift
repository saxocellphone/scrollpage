import XCTest
@testable import ScrollpageCore

private func tips(ti: Double, tm: Double = 0.5, im: Double = 0.5,
                     readable: Bool = true, middleReadable: Bool = true) -> TouchMeasure {
    TouchMeasure(thumbIndex: ti, thumbMiddle: tm, indexMiddle: im, readable: readable,
                 middleReadable: readable && middleReadable)
}

final class TouchClassifierTests: XCTestCase {
    private let detector = TouchDetector()

    func testPinchNeedsTipsTouchingAndTheMiddleFingerApart() {
        XCTAssertEqual(detector.pose(tips(ti: 0.026)), .pinch)
        XCTAssertEqual(detector.pose(tips(ti: 0.06)), .pinch)
        XCTAssertNil(detector.pose(tips(ti: 0.061)), "just above the touching cluster")
        XCTAssertNil(detector.pose(tips(ti: 0.13)), "hovering (10th percentile of near-touch frames)")
        XCTAssertNil(detector.pose(tips(ti: 0.8)), "open hand")
        XCTAssertEqual(detector.pose(tips(ti: 0.03, tm: 0.22, im: 0.4)), .pinch)
        XCTAssertNil(detector.pose(tips(ti: 0.03, tm: 0.21, im: 0.4)), "middle tip too close for a plain pinch")
    }

    func testThreeFingerNeedsAllThreeTipsTogether() {
        XCTAssertEqual(detector.pose(tips(ti: 0.03, tm: 0.05, im: 0.04)), .threeFinger)
        XCTAssertEqual(detector.pose(tips(ti: 0.12, tm: 0.12, im: 0.12)), .threeFinger)
        XCTAssertNil(detector.pose(tips(ti: 0.03, tm: 0.121, im: 0.05)))
        XCTAssertNil(detector.pose(tips(ti: 0.13, tm: 0.05, im: 0.05)), "thumb and index not touching")
    }

    /// Between the three-finger ceiling and the plain pinch's middle-apart
    /// floor neither touch can start, so one is never taken for the other.
    func testGapBetweenPinchAndThreeFinger() {
        for gap in stride(from: 0.125, through: 0.215, by: 0.01) {
            XCTAssertNil(detector.pose(tips(ti: 0.03, tm: gap, im: gap)), "middle gap \(gap)")
        }
        let t = TouchThresholds()
        XCTAssertLessThan(t.threeExit, t.middleApart)
        XCTAssertLessThan(t.pinchEnter, t.pinchExit)
        XCTAssertLessThan(t.threeEnter, t.threeExit)
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
            hand[joint]?.confidence = 0.45
            XCTAssertFalse(TouchMeasure(hand, handSize: size).readable, "\(joint)")
        }
        var hand = gen.sample(pose)
        hand[.middleTip]?.confidence = 0.45
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
        frame(ti: 0.05)
        XCTAssertTrue(detector.canMove)
        frame(ti: 0.09)
        XCTAssertFalse(detector.canMove, "parting fingers don't move the pointer")
        XCTAssertEqual(detector.active, .pinch)
        XCTAssertNil(frame(ti: 0.11), "one frame apart does not release")
        XCTAssertNil(frame(ti: 0.04))
        XCTAssertNil(frame(ti: 0.11))
        XCTAssertEqual(frame(ti: 0.11), .ended(.pinch, lifted: true))
        XCTAssertFalse(detector.canMove)
    }

    func testNoisyFrameDuringConfirmationNeitherCountsNorRestarts() {
        frames(3, ti: 0.8)
        frames(2, ti: 0.03)
        XCTAssertNil(frame(ti: 0.08))
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
        XCTAssertNil(step(0.12), "leaving the exit threshold starts over")
        XCTAssertNil(other.pending)
        _ = step(0.03); _ = step(0.03)
        XCTAssertEqual(step(0.03), .began(.pinch))
    }

    func testHoveringJustApartNeverTouches() {
        frames(3, ti: 0.8)
        for ti in stride(from: 0.065, through: 0.3, by: 0.005) {
            XCTAssertEqual(frames(10, ti: ti), [], "ti \(ti)")
            XCTAssertNil(detector.pending)
        }
    }

    func testUnreadableFramesHoldBrieflyThenEndWithoutLifting() {
        frames(3, ti: 0.8)
        frames(3, ti: 0.03)
        XCTAssertEqual(frames(5, ti: 0.03, hidden: [.thumbTip]), [], "0.17 s is within the grace")
        XCTAssertEqual(detector.active, .pinch)
        XCTAssertEqual(frames(3, ti: 0.03), [])
        XCTAssertEqual(frames(8, ti: 0.03, hidden: [.indexTip]), [.ended(.pinch, lifted: false)])
        XCTAssertNil(detector.active)
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

    func testHalfFormedThreeFingerIsNeitherTouch() {
        frames(3, ti: 0.8)
        XCTAssertEqual(frames(30, ti: 0.03, middle: 0.17), [], "middle tip near but not touching")
        XCTAssertNil(detector.active)
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
