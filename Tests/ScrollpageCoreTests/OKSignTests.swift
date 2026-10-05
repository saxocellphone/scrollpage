import XCTest
@testable import ScrollpageCore

private let others: [HandJoint] = [.middleMCP, .ringMCP, .littleMCP]

private func curled(_ c: Double, _ fingers: [HandJoint] = others) -> [HandJoint: Double] {
    Dictionary(uniqueKeysWithValues: fingers.map { ($0, c) })
}

final class FingerExtensionTests: XCTestCase {
    private var gen = SyntheticHand(sigma: 0, touchSigma: 0)

    private func reading(_ update: (inout HandPose) -> Void) -> FingerReading {
        var pose = HandPose()
        update(&pose)
        return gen.sample(pose).extensionReading(.ring)
    }

    func testReadingsAcrossACurl() {
        XCTAssertEqual(reading { _ in }, .extended)
        XCTAssertEqual(reading { $0.curl = [.ringMCP: 0.4] }, .extended, "relaxed")
        XCTAssertEqual(reading { $0.curl = [.ringMCP: 0.7] }, .extended, "ratio 0.93")
        XCTAssertEqual(reading { $0.curl = [.ringMCP: 0.75] }, .between, "ratio 0.88, 105 degrees")
        XCTAssertEqual(reading { $0.curl = [.ringMCP: 0.85] }, .curled)
        XCTAssertEqual(reading { $0.folded = [.ringMCP] }, .curled)
    }

    func testRotationDoesNotChangeTheReading() {
        for tilt in stride(from: -150.0, through: 180, by: 30) {
            XCTAssertEqual(reading { $0.tilt = tilt; $0.curl = [.ringMCP: 0.4] }, .extended, "tilt \(tilt)")
            XCTAssertEqual(reading { $0.tilt = tilt; $0.curl = [.ringMCP: 0.85] }, .curled, "tilt \(tilt)")
        }
    }

    /// With the wrist out of view the middle-joint angle decides.
    func testAngleDecidesWithoutTheWrist() {
        XCTAssertEqual(reading { $0.hidden = [.wrist]; $0.curl = [.ringMCP: 0.4] }, .extended)
        XCTAssertEqual(reading { $0.hidden = [.wrist]; $0.curl = [.ringMCP: 0.85] }, .curled)
        XCTAssertEqual(reading { $0.hidden = [.wrist, .ringMCP] }, .unreadable)
    }

    func testFlipsNeedConfirmationAndInBetweenHolds() {
        var tracker = FingerExtensionTracker()
        var pose = HandPose()
        func step(_ c: Double) {
            pose.curl = [.ringMCP: c]
            tracker.update(gen.sample(pose))
        }
        step(0.3)
        XCTAssertTrue(tracker.isExtended(.ring), "the first reading counts at once")
        step(0.9)
        XCTAssertTrue(tracker.isExtended(.ring), "one curled frame doesn't flip it")
        step(0.3)
        step(0.9)
        step(0.9)
        XCTAssertTrue(tracker.isCurled(.ring))
        for _ in 0..<10 { step(0.75) }
        XCTAssertTrue(tracker.isCurled(.ring), "in between keeps the state")
        step(0.3)
        step(0.3)
        for _ in 0..<10 { step(0.75) }
        XCTAssertTrue(tracker.isExtended(.ring))
    }
}

final class OKSignPinchTests: XCTestCase {
    /// Pinches, moves and lets go with `shape` applied throughout.
    private func pinchAndMove(seed: UInt64 = 1, _ shape: (inout HandPose) -> Void) -> Rig {
        let rig = Rig.webcam(seed: seed, fps: 30)
        shape(&rig.pose)
        rig.hold(0.6)
        rig.pinch(true, over: 0.08)
        rig.hold(0.1)
        rig.move(by: Vec2(1.0 * rig.pose.size, 0.3 * rig.pose.size), over: 0.6)
        rig.pinch(false, over: 0.08)
        rig.hold(0.3)
        return rig
    }

    private func assertNothing(_ rig: Rig, _ message: String) {
        XCTAssertEqual(rig.count(.touchBegan), 0, message)
        XCTAssertEqual(rig.count(.scrollBegan), 0, message)
        XCTAssertEqual(rig.pointerTravel().path, 0, message)
        XCTAssertTrue(rig.clicks.isEmpty, message)
    }

    func testCurledFingersNeverPoint() {
        for seed in UInt64(1)...3 {
            assertNothing(pinchAndMove(seed: seed) { $0.folded = [.ringMCP, .littleMCP] }, "ring and little curled, seed \(seed)")
            assertNothing(pinchAndMove(seed: seed) { $0.folded = [.middleMCP] }, "middle curled, seed \(seed)")
            assertNothing(pinchAndMove(seed: seed) { $0.folded = [.littleMCP] }, "little curled, seed \(seed)")
            assertNothing(pinchAndMove(seed: seed) { $0.fingersOpen = false }, "fist with the thumb on the index tip, seed \(seed)")
            assertNothing(pinchAndMove(seed: seed) { $0.curl = curled(0.9) }, "half-closed past tolerance, seed \(seed)")
        }
    }

    func testRelaxedOKSignPoints() {
        for seed in UInt64(1)...3 {
            let rig = pinchAndMove(seed: seed) { $0.curl = curled(0.4) }
            XCTAssertEqual(rig.count(.touchBegan), 1, "seed \(seed)")
            XCTAssertGreaterThan(rig.pointerTravel().net.x, 50, "seed \(seed)")
            XCTAssertEqual(rig.count(.touchEnded), 1, "seed \(seed)")
        }
    }

    /// A finger wobbling across one tolerance never starts or stops a touch. The
    /// wobble is about twice the frame-to-frame noise measured on the webcam
    /// (tip ratio 0.01), centred on the engage tolerance for an extended finger
    /// and on the release tolerance for a curled one.
    func testFingerWobblingAtTheBoundaryDoesNotFlicker() {
        for seed in UInt64(1)...4 {
            var noise = NoiseSource(seed: seed &+ 31)
            let rig = Rig.webcam(seed: seed, fps: 30)
            rig.pose.curl = curled(0.4)
            rig.hold(0.6)
            rig.pinch(true, over: 0.08)
            let home = rig.pose.palm
            rig.run(3) { p, pose in
                pose.curl[.ringMCP] = 0.71 + noise.gaussian(0.02)
                pose.palm = home + Vec2(sin(p * 2 * .pi * 2), 0) * (0.5 * pose.size)
            }
            XCTAssertEqual(rig.count(.touchBegan), 1, "seed \(seed)")
            XCTAssertEqual(rig.count(.touchEnded), 0, "seed \(seed)")
            XCTAssertGreaterThan(rig.pointerTravel().path, 100, "seed \(seed)")

            let curledRig = Rig.webcam(seed: seed, fps: 30)
            curledRig.pose.curl = curled(0.9, [.ringMCP])
            curledRig.hold(0.6)
            curledRig.pinch(true, over: 0.08)
            curledRig.run(3) { p, pose in
                pose.curl[.ringMCP] = 0.795 + noise.gaussian(0.02)
                pose.palm = home + Vec2(sin(p * 2 * .pi * 2), 0) * (0.5 * pose.size)
            }
            assertNothing(curledRig, "ring wobbling on the curled side, seed \(seed)")
        }
    }

    func testBriefDipMidDragKeepsTheDrag() {
        let rig = Rig.webcam(fps: 30)
        rig.hold(0.6)
        rig.pinch(true, over: 0.08)
        rig.hold(0.7)
        XCTAssertEqual(rig.count(.pressBegan), 1)
        rig.move(by: Vec2(0.5 * rig.pose.size, 0), over: 0.3)
        rig.pose.folded = [.ringMCP]
        rig.move(by: Vec2(0.2 * rig.pose.size, 0), over: 0.2)
        rig.pose.folded = []
        let resumed = rig.t
        rig.move(by: Vec2(0.5 * rig.pose.size, 0), over: 0.3)
        XCTAssertEqual(rig.count(.touchEnded), 0, "the drag survives the dip")
        XCTAssertGreaterThan(rig.pointerTravel(since: resumed).net.x, 20, "and keeps moving")
        rig.pinch(false, over: 0.08)
        rig.hold(0.2)
        XCTAssertEqual(rig.count(.touchEnded), 1)
        XCTAssertTrue(rig.clicks.isEmpty)
    }

    func testCurlingPastTheGraceEndsTheTouchWithoutAClick() {
        let rig = Rig.webcam(fps: 30)
        rig.hold(0.6)
        rig.pinch(true, over: 0.08)
        rig.hold(0.1)
        rig.pose.fingersOpen = false
        rig.hold(0.5)
        XCTAssertEqual(rig.count(.touchEnded), 1)
        let ended = rig.t
        rig.move(by: Vec2(0.8 * rig.pose.size, 0), over: 0.4)
        rig.pinch(false, over: 0.08)
        rig.hold(0.3)
        XCTAssertTrue(rig.clicks.isEmpty)
        XCTAssertEqual(rig.pointerTravel(since: ended).path, 0)
        XCTAssertEqual(rig.count(.touchBegan), 1)
    }

    func testCurlingFreezesThePointerDuringTheGrace() {
        let rig = Rig.webcam(fps: 30)
        rig.hold(0.6)
        rig.pinch(true, over: 0.08)
        rig.hold(0.1)
        rig.move(by: Vec2(0.5 * rig.pose.size, 0), over: 0.3)
        rig.pose.fingersOpen = false
        rig.hold(2 / 30)
        let curledAt = rig.t
        rig.move(by: Vec2(0.5 * rig.pose.size, 0), over: 0.2)
        XCTAssertEqual(rig.pointerTravel(since: curledAt + 1e-6).path, 0)
    }
}
