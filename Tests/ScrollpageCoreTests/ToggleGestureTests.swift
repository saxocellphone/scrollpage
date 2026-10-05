import XCTest
@testable import ScrollpageCore

private let hu = HandPose().size

private func shaped(_ base: HandPose = .peaceSign, _ change: (inout HandPose) -> Void) -> HandPose {
    var p = base
    change(&p)
    return p
}

/// Hand shapes that look a little like the peace sign but must never toggle.
private let nearMisses: [(String, HandPose)] = [
    ("V with the thumb stretched out", shaped { $0.thumbTucked = false; $0.spread = true }),
    ("V with the thumb relaxed beside it", shaped { $0.thumbTucked = false }),
    ("V with the thumb on the index tip", shaped { $0.thumbOn = .indexTip }),
    ("V with the thumb on the middle tip", shaped { $0.thumbOn = .middleTip }),
    ("index and middle together", shaped { $0.vAngle = 0 }),
    ("three fingers up", shaped { $0.folded = [.littleMCP] }),
    ("one finger up", shaped { $0.folded = [.middleMCP, .ringMCP, .littleMCP] }),
    ("open hand", HandPose()),
    ("raised palm, fingers spread", shaped(HandPose()) { $0.spread = true }),
    ("fist", shaped(HandPose()) { $0.fingersOpen = false; $0.thumbTucked = true }),
    ("OK pinch", shaped(HandPose()) { $0.pinchRatio = Rig.touching }),
    ("three-finger touch", shaped(HandPose()) { $0.pinchRatio = Rig.touching; $0.middleTouch = Rig.touching }),
    ("three-finger touch, ring and little curled",
     shaped(HandPose()) { $0.pinchRatio = Rig.touching; $0.middleTouch = Rig.touching; $0.folded = [.ringMCP, .littleMCP] }),
    ("V with the fingertips out of view", shaped { $0.hidden = [.indexTip, .middleTip] }),
]

final class PeaceSignPoseTests: XCTestCase {
    private func recognized(_ p: HandPose) -> Bool {
        var hand = SyntheticHand(sigma: 0)
        let sample = hand.sample(p)
        return ToggleGestureDetector().isPeaceSign(sample, handSize: sample.handSize!)
    }

    func testPeaceSignIsRecognized() {
        XCTAssertTrue(recognized(.peaceSign))
        XCTAssertTrue(recognized(shaped { $0.tilt = 25 }), "a slight lean is fine")
        XCTAssertTrue(recognized(shaped { $0.tilt = -25 }))
        XCTAssertTrue(recognized(shaped { $0.tilt = 90 }), "measured in the hand's own frame, so any turn of it")
        XCTAssertTrue(recognized(shaped { $0.vAngle = 40 }), "a wide V")
        XCTAssertTrue(recognized(shaped { $0.vAngle = 14 }), "a narrow one")
        XCTAssertTrue(recognized(shaped { $0.size = 0.10 }), "a small hand far from the camera")
    }

    func testNearMissesAreNot() {
        for (name, pose) in nearMisses {
            XCTAssertFalse(recognized(pose), name)
        }
    }

    /// Where the synthetic V sits against the tolerances.
    func testMeasureOfThePeaceSign() {
        var hand = SyntheticHand(sigma: 0)
        let sample = hand.sample(.peaceSign)
        let m = PeaceSignMeasure(sample, handSize: sample.handSize!)
        let th = PeaceSignThresholds()
        XCTAssertEqual(m.gap!, 0.57, accuracy: 0.01)
        XCTAssertEqual(m.angle!, 24, accuracy: 0.1)
        XCTAssertGreaterThan(m.reach!, 2 * th.reachEnter)
        XCTAssertGreaterThan(m.thumbApart!, 2 * th.thumbApartEnter)
        XCTAssertLessThan(m.thumbNear!, th.thumbNearEnter)
        XCTAssertGreaterThan(m.thumbAcross!, th.thumbAcrossEnter)
        XCTAssertTrue(m.matches(th, holding: false))
    }
}

final class ToggleGestureTests: XCTestCase {
    private let hold = ToggleGestureConfig().holdDuration

    func testHoldTogglesAtHalfASecondNotBefore() {
        XCTAssertEqual(hold, 0.5)
        let rig = Rig()
        rig.hold(0.5)
        rig.peaceSign(true)
        let entered = rig.t
        rig.hold(hold - 0.03)
        XCTAssertTrue(rig.toggles.isEmpty, "not before the hold")
        XCTAssertTrue(rig.engine.controlOn)
        rig.hold(0.1)
        XCTAssertEqual(rig.toggles.count, 1)
        XCTAssertEqual(rig.toggles.first?.on, false)
        XCTAssertFalse(rig.engine.controlOn)
        // The ring and little fingers take two frames to read as curled.
        let held = rig.toggles[0].t - entered
        XCTAssertGreaterThanOrEqual(held, hold)
        XCTAssertLessThan(held, hold + 0.05)
    }

    func testProgressShowsOnlyAfterAQuarterSecond() {
        let rig = Rig()
        rig.hold(0.5)
        rig.peaceSign(true)
        let entered = rig.t
        rig.hold(hold)
        XCTAssertTrue(rig.toggles.isEmpty)
        let early = rig.progress.filter { $0.t - entered < 0.25 }.map(\.value)
        XCTAssertEqual(early.max(), 0, "a hand passing through the pose shows nothing")
        let late = rig.progress.filter { $0.t - entered > 0.3 }.map(\.value)
        XCTAssertGreaterThan(late.first ?? 0, 0)
        XCTAssertEqual(late, late.sorted(), "progress only rises while holding")
        XCTAssertGreaterThan(late.last ?? 0, 0.8)
    }

    func testMovingRestartsTheHold() {
        let rig = Rig()
        rig.hold(0.5)
        rig.peaceSign(true)
        rig.hold(0.4)
        rig.move(by: Vec2(0.5 * hu, 0), over: 0.3)
        let stopped = rig.t
        rig.hold(0.3)
        XCTAssertTrue(rig.toggles.isEmpty, "the hold restarted when the hand moved")
        rig.hold(0.4)
        XCTAssertEqual(rig.toggles.count, 1)
        XCTAssertGreaterThanOrEqual(rig.toggles[0].t - stopped, hold - 0.05)
    }

    func testSlowDriftRestartsTheHold() {
        let rig = Rig()
        rig.hold(0.5)
        rig.peaceSign(true)
        // 0.36 hu/s: below the speed limit, but it wanders more than 0.15 hu
        // before half a second is up.
        let start = rig.pose.palm
        rig.run(1.5) { p, pose in pose.palm = start + Vec2(0.54 * hu * p, 0) }
        XCTAssertTrue(rig.toggles.isEmpty)
    }

    func testAFastVNeverTogglesOrFlings() {
        let rig = Rig()
        rig.hold(0.5)
        rig.peaceSign(true)
        for i in 0..<8 {
            rig.hold(0.2)
            rig.move(by: Vec2(0, (i.isMultiple(of: 2) ? -0.6 : 0.6) * hu), over: 0.12)
        }
        XCTAssertTrue(rig.toggles.isEmpty)
        XCTAssertTrue(rig.flings.isEmpty, "two fingers up is not an open hand, so it never flicks")
        XCTAssertTrue(rig.outputs.isEmpty, "\(rig.outputs.map(\.output))")
    }

    func testHoldingTheVStillNeverFlingsOrMoves() {
        let rig = Rig()
        rig.hold(0.5)
        rig.peaceSign(true)
        rig.hold(3.0)
        XCTAssertEqual(rig.toggles.count, 1)
        XCTAssertTrue(rig.flings.isEmpty)
        XCTAssertTrue(rig.clicks.isEmpty)
        XCTAssertEqual(rig.pointerTravel().path, 0)
    }

    func testNearMissesHeldStillNeverToggle() {
        for (name, shape) in nearMisses {
            let rig = Rig()
            rig.hold(0.5)
            rig.pose = shape
            rig.hold(3.0)
            XCTAssertTrue(rig.toggles.isEmpty, name)
            XCTAssertTrue(rig.engine.controlOn, name)
            XCTAssertEqual(rig.progress.map(\.value).max(), 0, name)
        }
    }

    func testRaisedPalmIsJustALiftedFinger() {
        let rig = Rig()
        rig.hold(0.5)
        rig.pose.spread = true
        rig.hold(4.0)
        XCTAssertTrue(rig.toggles.isEmpty)
        XCTAssertTrue(rig.outputs.isEmpty, "\(rig.outputs.map(\.output))")
        rig.move(by: Vec2(0, -0.6 * hu), over: 0.12)
        rig.hold(0.3)
        XCTAssertEqual(rig.flings.count, 1, "a flick of the spread hand still scrolls")
    }

    func testOneTogglePerHold() {
        let rig = Rig()
        rig.hold(0.5)
        rig.peaceSign(true)
        rig.hold(4.0)
        XCTAssertEqual(rig.toggles.count, 1, "holding on doesn't toggle again")

        rig.peaceSign(false)
        rig.hold(0.2)
        rig.peaceSign(true)
        rig.hold(3.0)
        XCTAssertEqual(rig.toggles.count, 1, "leaving the pose for less than 0.3 s doesn't re-arm")

        rig.peaceSign(false)
        rig.hold(0.4)
        rig.peaceSign(true)
        rig.hold(hold + 0.05)
        XCTAssertEqual(rig.toggles.map(\.on), [false, true], "leave, make the V again and hold: back on")
    }

    func testCoolDownSpacesToggles() {
        let rig = Rig()
        rig.hold(0.5)
        rig.peaceSign(true)
        rig.hold(hold + 0.05)
        XCTAssertEqual(rig.toggles.count, 1)
        rig.peaceSign(false)
        rig.hold(0.35)
        rig.peaceSign(true)
        rig.hold(3.0)
        XCTAssertEqual(rig.toggles.count, 2)
        // Re-armed after 0.35 s and held half a second: 0.9 s, held back to 1.5 s.
        XCTAssertEqual(rig.toggles[1].t - rig.toggles[0].t, 1.5, accuracy: 0.02)
    }

    func testLeavingTheFrameReArms() {
        let rig = Rig()
        rig.hold(0.5)
        rig.peaceSign(true)
        rig.hold(hold + 0.05)
        rig.run(1.0, visible: false)
        rig.hold(1.0)
        XCTAssertEqual(rig.toggles.map(\.on), [false, true])
    }

    func testBriefTrackingDropoutDoesNotRestartTheHold() {
        let rig = Rig()
        rig.hold(0.5)
        rig.peaceSign(true)
        let entered = rig.t
        rig.hold(0.3)
        rig.run(0.05, visible: false)
        rig.hold(0.3)
        XCTAssertEqual(rig.toggles.count, 1)
        let held = rig.toggles[0].t - entered
        XCTAssertGreaterThanOrEqual(held, hold)
        XCTAssertLessThan(held, hold + 0.05)
    }

    func testLoweringTheHandAfterTogglingDoesNotFling() {
        let rig = Rig()
        rig.hold(0.5)
        rig.setControl(false)
        rig.peaceSign(true)
        rig.hold(hold + 0.05)
        XCTAssertEqual(rig.toggles.map(\.on), [true])
        rig.peaceSign(false)
        rig.move(by: Vec2(0, 0.6 * hu), over: 0.12)
        rig.hold(0.6)
        XCTAssertTrue(rig.flings.isEmpty, "opening the hand and dropping it right after the toggle")

        rig.move(by: Vec2(0, -0.6 * hu), over: 0.12)
        rig.hold(0.3)
        XCTAssertEqual(rig.flings.count, 1, "a deliberate flick afterwards scrolls")
    }

    func testNoToggleDuringAScrollUntilRelease() {
        let rig = Rig()
        rig.hold(0.5)
        rig.threeFinger(true)
        rig.move(by: Vec2(0, 0.3 * hu), over: 0.3)
        XCTAssertTrue(rig.engine.snapshot.isScrolling)
        rig.pose.pinchRatio = 0.8
        rig.pose.middleTouch = nil
        rig.peaceSign(true)
        rig.hold(2.0)
        XCTAssertEqual(rig.count(.scrollBegan), 1)
        let released = rig.outputs.first { if case .scrollEnded = $0.output { return true } else { return false } }?.t
        XCTAssertNotNil(released)
        XCTAssertEqual(rig.toggles.count, 1)
        if let released, let fired = rig.toggles.first?.t {
            // From the first frame after the touch ends, not the frame it ends on.
            XCTAssertGreaterThanOrEqual(fired - released, hold + rig.dt / 2, "the hold starts once the fingers lift")
        }
    }

    func testNoToggleDuringAPinchUntilRelease() {
        let rig = Rig()
        rig.hold(0.5)
        rig.pinch(true)
        rig.hold(0.8)
        XCTAssertTrue(rig.engine.snapshot.isPressed)
        // A V while the thumb still holds the index tip: the pinch stays down.
        rig.pose.pinchRatio = 0.8
        rig.pose.vAngle = 24
        rig.pose.thumbOn = .indexTip
        rig.hold(2.0)
        XCTAssertTrue(rig.engine.snapshot.isTouching)
        XCTAssertTrue(rig.toggles.isEmpty)
        XCTAssertEqual(rig.progress.map(\.value).max(), 0)

        rig.pose.thumbOn = nil
        rig.peaceSign(true)
        rig.hold(2.0)
        XCTAssertFalse(rig.engine.snapshot.isTouching)
        let released = rig.outputs.first { $0.output == .touchEnded }?.t
        XCTAssertEqual(rig.toggles.count, 1)
        if let released, let fired = rig.toggles.first?.t {
            XCTAssertGreaterThanOrEqual(fired - released, hold + rig.dt / 2)
        }
    }
}

/// The detector by itself: confirmation, hysteresis and availability.
final class ToggleDetectorTests: XCTestCase {
    private struct Feed {
        var detector = ToggleGestureDetector()
        var hand = SyntheticHand(sigma: 0)
        var t = 0.0
        var fired: [Double] = []

        mutating func frames(_ n: Int, _ pose: HandPose, available: Bool = true, dt: Double = 1.0 / 30) {
            for _ in 0..<n {
                t += dt
                let s = hand.sample(pose)
                if detector.update(s, handSize: s.handSize!, position: .zero, speed: 0, available: available, at: t) {
                    fired.append(t)
                }
            }
        }
    }

    func testThePoseMustReadSeveralFramesInARow() {
        var f = Feed()
        f.frames(10, HandPose())
        for _ in 0..<20 {
            f.frames(2, .peaceSign)
            XCTAssertFalse(f.detector.inPose)
            f.frames(1, HandPose())
        }
        XCTAssertTrue(f.fired.isEmpty, "two-frame flashes of a V never count")
        f.frames(3, .peaceSign)
        XCTAssertTrue(f.detector.inPose)
    }

    func testTheHoldIsTimedFromTheFirstFrameOfThePose() {
        var f = Feed()
        f.frames(10, HandPose())
        let entered = f.t
        f.frames(30, .peaceSign)
        XCTAssertEqual(f.fired.count, 1)
        // Frame 1 is the ring and little fingers' first curled reading; on frame
        // 2 they count as curled, frame 4 confirms the pose and the hold runs from frame 2.
        XCTAssertEqual(f.fired[0] - entered, ToggleGestureConfig().holdDuration + 2.0 / 30, accuracy: 1e-6)
    }

    func testANarrowingVStaysInThePoseButCannotStartIt() {
        var f = Feed()
        f.frames(10, HandPose())
        f.frames(30, shaped { $0.vAngle = 10 })
        XCTAssertFalse(f.detector.inPose, "10 degrees is below the enter angle")
        XCTAssertTrue(f.fired.isEmpty)

        f.frames(10, HandPose())
        f.frames(5, .peaceSign)
        f.frames(25, shaped { $0.vAngle = 10 })
        XCTAssertEqual(f.fired.count, 1, "but above the exit angle once in")

        f.frames(5, shaped { $0.vAngle = 5 })
        XCTAssertFalse(f.detector.inPose, "5 degrees is below the exit angle")
    }

    func testAFingerBetweenTheTolerancesKeepsItsState() {
        var f = Feed()
        f.frames(10, HandPose())
        f.frames(5, .peaceSign)
        // The ring finger partly opens, between curled and extended.
        f.frames(25, shaped { $0.folded = [.littleMCP]; $0.curl[.ringMCP] = 0.75 })
        XCTAssertEqual(f.fired.count, 1)
        XCTAssertTrue(f.detector.fingers.isCurled(.ring))

        var g = Feed()
        g.frames(10, HandPose())
        g.frames(30, shaped { $0.folded = [.littleMCP]; $0.curl[.ringMCP] = 0.75 })
        XCTAssertTrue(g.fired.isEmpty, "a ring finger last seen extended stays extended")
    }

    func testUnavailableFramesDoNotCount() {
        var f = Feed()
        f.frames(10, HandPose())
        f.frames(60, .peaceSign, available: false)
        XCTAssertTrue(f.fired.isEmpty)
        XCTAssertFalse(f.detector.isHolding)
        let freed = f.t
        f.frames(30, .peaceSign)
        XCTAssertEqual(f.fired.count, 1)
        XCTAssertEqual(f.fired[0] - freed, ToggleGestureConfig().holdDuration + 1.0 / 30, accuracy: 1e-6)
    }
}

final class ControlGatingTests: XCTestCase {
    private func turnOffByGesture(_ rig: Rig) {
        rig.hold(0.5)
        rig.peaceSign(true)
        rig.hold(0.6)
        rig.peaceSign(false)
        rig.hold(1.0)
        XCTAssertEqual(rig.toggles.map(\.on), [false])
    }

    private var postingOutputs: (GestureOutput) -> Bool {
        { output in
            switch output {
            case .pointerMoved, .click, .pressBegan, .fling, .touchBegan, .scrollBegan, .scrolled: return true
            case .touchEnded, .catchGlide, .scrollEnded: return false
            }
        }
    }

    func testNothingIsPostedWhileOff() {
        let rig = Rig()
        turnOffByGesture(rig)
        rig.clearOutputs()

        rig.pinch(true)
        rig.move(by: Vec2(0.6 * hu, 0), over: 0.5)
        rig.pinch(false)
        rig.hold(0.4)
        rig.pinch(true)
        rig.hold(0.05)
        rig.pinch(false)
        rig.hold(0.4)
        rig.pinch(true)
        rig.hold(1.0)
        rig.move(by: Vec2(0.3 * hu, 0), over: 0.3)
        rig.pinch(false)
        rig.hold(0.5)
        rig.move(by: Vec2(0, -0.6 * hu), over: 0.12)
        rig.hold(0.5)
        rig.threeFinger(true)
        rig.move(by: Vec2(0, 0.6 * hu), over: 0.4)
        rig.threeFinger(false)
        rig.hold(0.5)
        rig.pose.spread = true
        rig.hold(2.0)

        XCTAssertTrue(rig.outputs.isEmpty, "\(rig.outputs.map(\.output))")
        XCTAssertTrue(rig.toggles.isEmpty)
        XCTAssertFalse(rig.engine.snapshot.isTouching)
        XCTAssertFalse(rig.engine.snapshot.controlOn)
    }

    func testToggleOnIsStillDetectedWhileOffAndGesturesResume() {
        let rig = Rig()
        turnOffByGesture(rig)
        rig.peaceSign(true)
        rig.hold(0.6)
        XCTAssertEqual(rig.toggles.map(\.on), [false, true])
        XCTAssertTrue(rig.engine.controlOn)

        rig.peaceSign(false)
        rig.hold(0.5)
        rig.clearOutputs()
        rig.pinch(true)
        rig.hold(0.05)
        rig.pinch(false)
        rig.hold(0.6)
        XCTAssertEqual(rig.clicks, [1])
        rig.move(by: Vec2(0, -0.6 * hu), over: 0.12)
        rig.hold(0.3)
        XCTAssertEqual(rig.flings.count, 1)
    }

    func testToggleOnWithPinchAlreadyClosedDoesNotGrab() {
        let rig = Rig()
        rig.hold(0.5)
        rig.setControl(false)
        rig.pinch(true)
        rig.hold(0.5)
        rig.clearOutputs()
        rig.setControl(true)
        rig.move(by: Vec2(0.5 * hu, 0), over: 0.4)
        rig.pinch(false)
        rig.hold(0.3)
        XCTAssertEqual(rig.count(.touchBegan), 0)
        XCTAssertEqual(rig.pointerTravel().path, 0)
        XCTAssertTrue(rig.clicks.isEmpty)
    }

    func testTurningOffMidDragReleasesTheButton() {
        let rig = Rig()
        rig.hold(0.5)
        rig.pinch(true)
        rig.hold(0.8)
        rig.move(by: Vec2(0.3 * hu, 0), over: 0.3)
        XCTAssertEqual(rig.count(.pressBegan), 1)
        XCTAssertTrue(rig.engine.snapshot.isPressed)
        rig.clearOutputs()

        rig.setControl(false)
        XCTAssertEqual(rig.outputs.map(\.output), [.touchEnded], "release the button, nothing else")

        rig.move(by: Vec2(0.3 * hu, 0), over: 0.3)
        rig.pinch(false)
        rig.hold(0.3)
        XCTAssertEqual(rig.outputs.map(\.output), [.touchEnded])
        XCTAssertFalse(rig.engine.snapshot.isTouching)
        XCTAssertFalse(rig.engine.snapshot.isPressed)
    }

    func testTurningOffMidTapDoesNotClick() {
        let rig = Rig()
        rig.hold(0.5)
        rig.pinch(true)
        rig.hold(0.05)
        rig.setControl(false)
        rig.pinch(false)
        rig.hold(0.5)
        XCTAssertTrue(rig.clicks.isEmpty)
        XCTAssertEqual(rig.count(.touchEnded), 1)
    }

    func testTurningOffDuringAGlideCatchesIt() {
        let rig = Rig()
        rig.hold(0.5)
        rig.move(by: Vec2(0, -0.6 * hu), over: 0.12)
        rig.hold(0.2)
        XCTAssertEqual(rig.flings.count, 1)
        rig.clearOutputs()
        rig.peaceSign(true)
        rig.hold(0.6)
        XCTAssertEqual(rig.toggles.map(\.on), [false])
        XCTAssertEqual(rig.outputs.map(\.output), [.catchGlide, .touchBegan, .touchEnded],
                       "a finger landing stops the glide, then lifts")
        XCTAssertTrue(rig.outputs.allSatisfy { $0.t == rig.toggles[0].t })
    }

    func testMenuSwitchIsTheSameControlState() {
        let rig = Rig()
        rig.hold(0.5)
        XCTAssertEqual(rig.engine.setControl(on: true), [], "already on")
        rig.setControl(false)
        XCTAssertFalse(rig.engine.controlOn)
        XCTAssertFalse(rig.engine.snapshot.controlOn)
        XCTAssertEqual(rig.engine.setControl(on: false), [], "already off")

        rig.peaceSign(true)
        rig.hold(0.6)
        XCTAssertEqual(rig.toggles.map(\.on), [true], "the gesture turns the menu's Off back on")
        rig.setControl(false)
        rig.peaceSign(false)
        rig.hold(1.2)
        rig.peaceSign(true)
        rig.hold(0.6)
        XCTAssertEqual(rig.toggles.map(\.on), [true, true])
    }

    func testControlStateSurvivesLosingTheHand() {
        let rig = Rig()
        turnOffByGesture(rig)
        rig.clearOutputs()
        rig.run(1.0, visible: false)
        XCTAssertFalse(rig.engine.snapshot.controlOn)
        _ = rig.engine.reset()
        XCTAssertFalse(rig.engine.controlOn)
        rig.hold(0.5)
        rig.pinch(true)
        rig.move(by: Vec2(0.5 * hu, 0), over: 0.4)
        XCTAssertTrue(rig.outputs.filter { postingOutputs($0.output) }.isEmpty)
    }
}

/// The toggle at the noise level and frame rate of a real USB webcam.
final class ToggleGestureWebcamTests: XCTestCase {
    func testPeaceSignTogglesOnceOnAWebcam() {
        for seed in UInt64(1)...8 {
            let rig = Rig.webcam(seed: seed)
            rig.hold(0.5)
            rig.peaceSign(true)
            let entered = rig.t
            rig.hold(2.5)
            XCTAssertEqual(rig.toggles.count, 1, "seed \(seed)")
            if let fired = rig.toggles.first {
                XCTAssertEqual(fired.t - entered, ToggleGestureConfig().holdDuration, accuracy: 0.12, "seed \(seed)")
            }
        }
    }

    func testOrdinaryUseOnAWebcamNeverToggles() {
        for seed in UInt64(1)...4 {
            let rig = Rig.webcam(seed: seed)
            let u = rig.pose.size
            rig.hold(3.0)
            rig.pinch(true, over: 0.08)
            rig.move(by: Vec2(0.5 * u, 0.2 * u), over: 0.5)
            rig.hold(1.5)
            rig.pinch(false, over: 0.08)
            rig.hold(1.0)
            rig.pose.spread = true
            rig.hold(2.0)
            rig.pose.spread = false
            rig.pose.fingersOpen = false
            rig.pose.thumbTucked = true
            rig.hold(2.0)
            rig.pose.fingersOpen = true
            rig.pose.folded = [.middleMCP, .ringMCP, .littleMCP]
            rig.hold(2.0)
            XCTAssertTrue(rig.toggles.isEmpty, "seed \(seed)")
        }
    }

    func testNearMissesOnAWebcamNeverToggle() {
        for (name, shape) in nearMisses {
            for seed in UInt64(1)...3 {
                let rig = Rig.webcam(seed: seed)
                rig.hold(0.5)
                var pose = shape
                pose.size = rig.pose.size
                pose.palm = rig.pose.palm
                rig.pose = pose
                rig.hold(3.0)
                XCTAssertTrue(rig.toggles.isEmpty, "\(name), seed \(seed)")
            }
        }
    }
}
