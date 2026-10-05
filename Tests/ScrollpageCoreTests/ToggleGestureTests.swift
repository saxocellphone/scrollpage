import XCTest
@testable import ScrollpageCore

private let hu = HandPose().size

private func shaped(_ change: (inout HandPose) -> Void) -> HandPose {
    var p = HandPose()
    change(&p)
    return p
}

final class RaisedPalmPoseTests: XCTestCase {
    private func recognized(_ p: HandPose) -> Bool {
        var hand = SyntheticHand(sigma: 0)
        let sample = hand.sample(p)
        return ToggleGestureDetector().isRaisedPalm(sample, handSize: sample.handSize!)
    }

    func testRaisedPalmIsRecognized() {
        XCTAssertTrue(recognized(.raisedPalm))
        XCTAssertTrue(recognized(shaped { $0.spread = true; $0.tilt = 25 }), "a slight lean is fine")
        XCTAssertTrue(recognized(shaped { $0.spread = true; $0.tilt = -25 }))
    }

    func testOtherHandShapesAreNot() {
        XCTAssertFalse(recognized(HandPose()), "open hand, fingers together (the lifted finger)")
        XCTAssertFalse(recognized(shaped { $0.fingersOpen = false }), "fist")
        XCTAssertFalse(recognized(shaped { $0.spread = true; $0.pinchRatio = 0.1 }), "pinch")
        XCTAssertFalse(recognized(shaped { $0.spread = true; $0.thumbTucked = true }), "four fingers, thumb folded")
        XCTAssertFalse(recognized(shaped { $0.spread = true; $0.folded = [.ringMCP] }), "one finger curled")
        XCTAssertFalse(recognized(shaped { $0.spread = true; $0.folded = [.middleMCP, .ringMCP] }))
        XCTAssertFalse(recognized(shaped { $0.spread = true; $0.tilt = 60 }), "hand leaning sideways")
        XCTAssertFalse(recognized(shaped { $0.spread = true; $0.tilt = 180 }), "hand pointing down")
        XCTAssertFalse(recognized(shaped { $0.spread = true; $0.hidden = [.littleTip, .ringTip] }), "fingertips out of view")
        XCTAssertFalse(recognized(shaped { $0.spread = true; $0.hidden = [.thumbTip] }))
    }
}

final class ToggleGestureTests: XCTestCase {
    private func raise(_ rig: Rig) { rig.pose.spread = true }
    private func lower(_ rig: Rig) { rig.pose.spread = false }

    func testHoldTogglesAfterAboutOneSecond() {
        let rig = Rig()
        rig.hold(0.5)
        raise(rig)
        let entered = rig.t
        rig.hold(0.95)
        XCTAssertTrue(rig.toggles.isEmpty, "not before a second")
        XCTAssertTrue(rig.engine.controlOn)
        rig.hold(0.1)
        XCTAssertEqual(rig.toggles.count, 1)
        XCTAssertEqual(rig.toggles.first?.on, false)
        XCTAssertFalse(rig.engine.controlOn)
        let held = rig.toggles[0].t - entered
        XCTAssertEqual(held, 1.0, accuracy: 0.04)
    }

    func testProgressShowsOnlyAfterThePalmSettles() {
        let rig = Rig()
        rig.hold(0.5)
        raise(rig)
        let entered = rig.t
        rig.hold(0.99)
        let early = rig.progress.filter { $0.t - entered < 0.28 }.map(\.value)
        XCTAssertEqual(early.max(), 0, "a palm passing through shows nothing")
        let late = rig.progress.filter { $0.t - entered > 0.32 }.map(\.value)
        XCTAssertGreaterThan(late.first ?? 0, 0)
        XCTAssertEqual(late, late.sorted(), "progress only rises while holding")
        XCTAssertGreaterThan(late.last ?? 0, 0.9)
    }

    func testMovingRestartsTheHold() {
        let rig = Rig()
        rig.hold(0.5)
        raise(rig)
        rig.hold(0.7)
        rig.move(by: Vec2(0.5 * hu, 0), over: 0.3)
        let stopped = rig.t
        rig.hold(0.8)
        XCTAssertTrue(rig.toggles.isEmpty, "the hold restarted when the hand moved")
        rig.hold(0.4)
        XCTAssertEqual(rig.toggles.count, 1)
        XCTAssertGreaterThanOrEqual(rig.toggles[0].t - stopped, 0.95)
    }

    func testSlowDriftRestartsTheHold() {
        let rig = Rig()
        rig.hold(0.5)
        raise(rig)
        // 0.3 hu/s: below the speed limit, but it wanders more than 0.2 hu.
        let start = rig.pose.palm
        rig.run(1.2) { p, pose in pose.palm = start + Vec2(0.36 * hu * p, 0) }
        XCTAssertTrue(rig.toggles.isEmpty)
    }

    func testOtherHandShapesHeldStillNeverToggle() {
        let shapes: [(String, HandPose)] = [
            ("open hand", HandPose()),
            ("fist", shaped { $0.fingersOpen = false }),
            ("pinch", shaped { $0.spread = true; $0.pinchRatio = 0.1 }),
            ("thumb tucked", shaped { $0.spread = true; $0.thumbTucked = true }),
            ("finger curled", shaped { $0.spread = true; $0.folded = [.ringMCP] }),
            ("leaning", shaped { $0.spread = true; $0.tilt = 60 }),
            ("fingertips cut off", shaped { $0.spread = true; $0.hidden = [.middleTip, .ringTip, .littleTip] }),
        ]
        for (name, shape) in shapes {
            let rig = Rig()
            rig.hold(0.5)
            rig.pose = shape
            rig.hold(3.0)
            XCTAssertTrue(rig.toggles.isEmpty, name)
            XCTAssertTrue(rig.engine.controlOn, name)
        }
    }

    func testOneTogglePerHold() {
        let rig = Rig()
        rig.hold(0.5)
        raise(rig)
        rig.hold(4.0)
        XCTAssertEqual(rig.toggles.count, 1, "holding on doesn't toggle again")

        lower(rig)
        rig.hold(0.15)
        raise(rig)
        rig.hold(3.0)
        XCTAssertEqual(rig.toggles.count, 1, "a dip shorter than the release time doesn't re-arm")

        lower(rig)
        rig.hold(0.5)
        raise(rig)
        rig.hold(1.1)
        XCTAssertEqual(rig.toggles.map(\.on), [false, true], "lower, raise again and hold: back on")
    }

    func testRefractoryPeriodSpacesToggles() {
        let rig = Rig()
        rig.hold(0.5)
        raise(rig)
        rig.hold(1.05)
        XCTAssertEqual(rig.toggles.count, 1)
        lower(rig)
        rig.hold(0.35)
        raise(rig)
        rig.hold(3.0)
        XCTAssertEqual(rig.toggles.count, 2)
        // Re-armed after 0.35 s and held a second: 1.4 s, held back to 1.5 s.
        XCTAssertEqual(rig.toggles[1].t - rig.toggles[0].t, 1.5, accuracy: 0.02)
    }

    func testLeavingTheFrameReArms() {
        let rig = Rig()
        rig.hold(0.5)
        raise(rig)
        rig.hold(1.1)
        rig.run(1.0, visible: false)
        rig.hold(1.1)
        XCTAssertEqual(rig.toggles.map(\.on), [false, true])
    }

    func testBriefTrackingDropoutDoesNotRestartTheHold() {
        let rig = Rig()
        rig.hold(0.5)
        raise(rig)
        let entered = rig.t
        rig.hold(0.5)
        rig.run(0.05, visible: false)
        rig.hold(0.5)
        XCTAssertEqual(rig.toggles.count, 1)
        XCTAssertEqual(rig.toggles[0].t - entered, 1.0, accuracy: 0.04)
    }

    func testFlicksThroughTheRaisedPalmScrollButNeverToggle() {
        let rig = Rig()
        rig.hold(0.5)
        raise(rig)
        for i in 0..<6 {
            rig.hold(0.4)
            rig.move(by: Vec2(0, (i.isMultiple(of: 2) ? -0.6 : 0.6) * hu), over: 0.12)
        }
        rig.hold(0.3)
        XCTAssertTrue(rig.toggles.isEmpty)
        XCTAssertFalse(rig.flings.isEmpty, "a flick with the hand spread still scrolls")
    }

    func testHoldingThePalmStillNeverFlingsOrMoves() {
        let rig = Rig()
        rig.hold(0.5)
        raise(rig)
        rig.hold(1.2)
        XCTAssertEqual(rig.toggles.count, 1)
        XCTAssertTrue(rig.flings.isEmpty)
        XCTAssertTrue(rig.clicks.isEmpty)
        XCTAssertEqual(rig.pointerTravel().path, 0)
    }

    func testLoweringTheHandAfterTurningOnDoesNotScroll() {
        for spreadWhileLowering in [false, true] {
            let rig = Rig()
            rig.hold(0.5)
            rig.setControl(false)
            raise(rig)
            rig.hold(1.05)
            XCTAssertEqual(rig.toggles.map(\.on), [true])
            if !spreadWhileLowering { lower(rig) }
            rig.move(by: Vec2(0, 0.6 * hu), over: 0.12)
            rig.hold(0.6)
            XCTAssertTrue(rig.flings.isEmpty, "spread while lowering: \(spreadWhileLowering)")

            lower(rig)
            rig.hold(0.6)
            rig.move(by: Vec2(0, -0.6 * hu), over: 0.12)
            rig.hold(0.3)
            XCTAssertEqual(rig.flings.count, 1, "a deliberate flick afterwards scrolls")
        }
    }
}

final class ControlGatingTests: XCTestCase {
    private func turnOffByGesture(_ rig: Rig) {
        rig.hold(0.5)
        rig.pose.spread = true
        rig.hold(1.1)
        rig.pose.spread = false
        rig.hold(0.5)
        XCTAssertEqual(rig.toggles.map(\.on), [false])
    }

    private var postingOutputs: (GestureOutput) -> Bool {
        { output in
            switch output {
            case .pointerMoved, .click, .pressBegan, .fling, .touchBegan: return true
            case .touchEnded: return false
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

        XCTAssertTrue(rig.outputs.isEmpty, "\(rig.outputs.map(\.output))")
        XCTAssertFalse(rig.engine.snapshot.isTouching)
        XCTAssertFalse(rig.engine.snapshot.controlOn)
    }

    func testToggleOnIsStillDetectedWhileOffAndGesturesResume() {
        let rig = Rig()
        turnOffByGesture(rig)
        rig.pose.spread = true
        rig.hold(1.1)
        XCTAssertEqual(rig.toggles.map(\.on), [false, true])
        XCTAssertTrue(rig.engine.controlOn)

        rig.pose.spread = false
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
        rig.pose.spread = true
        rig.hold(1.1)
        XCTAssertEqual(rig.toggles.map(\.on), [false])
        XCTAssertEqual(rig.outputs.map(\.output), [.touchBegan, .touchEnded],
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

        rig.pose.spread = true
        rig.hold(1.1)
        XCTAssertEqual(rig.toggles.map(\.on), [true], "the gesture turns the menu's Off back on")
        rig.setControl(false)
        rig.pose.spread = false
        rig.hold(0.5)
        rig.pose.spread = true
        rig.hold(1.1)
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
    func testRaisedPalmTogglesOnceOnAWebcam() {
        for seed in UInt64(1)...8 {
            let rig = Rig.webcam(seed: seed)
            rig.hold(0.5)
            rig.pose.spread = true
            let entered = rig.t
            rig.hold(2.5)
            XCTAssertEqual(rig.toggles.count, 1, "seed \(seed)")
            if let fired = rig.toggles.first {
                XCTAssertEqual(fired.t - entered, 1.0, accuracy: 0.12, "seed \(seed)")
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
            rig.hold(2.0)
            rig.pose.fingersOpen = false
            rig.hold(2.0)
            XCTAssertTrue(rig.toggles.isEmpty, "seed \(seed)")
        }
    }
}
