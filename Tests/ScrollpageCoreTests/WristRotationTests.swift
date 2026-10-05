import XCTest
@testable import ScrollpageCore



final class WristRotationTests: XCTestCase {
    /// A webcam rig pinching with the hand still.
    private func pinched(seed: UInt64 = 1, _ shape: (inout HandPose) -> Void = { _ in }) -> Rig {
        let rig = Rig.webcam(seed: seed, fps: 30)
        shape(&rig.pose)
        rig.hold(0.6)
        rig.pinch(true, over: 0.08)
        rig.hold(0.3)
        rig.clearOutputs()
        return rig
    }

    private func turn(_ rig: Rig, by degrees: Double, over duration: Double) {
        let from = rig.pose.tilt
        rig.run(duration) { p, pose in pose.tilt = from + degrees * minimumJerk(p) }
        rig.hold(0.2)
    }

    private func tip(_ rig: Rig, to foreshortening: Double, over duration: Double) {
        let from = rig.pose.foreshortening
        rig.run(duration) { p, pose in pose.foreshortening = from + (foreshortening - from) * minimumJerk(p) }
        rig.hold(0.2)
    }

    func testTurningAtTheWristAloneMovesThePointer() {
        for seed in UInt64(1)...3 {
            let rig = pinched(seed: seed) { $0.pivotAtWrist = true }
            turn(rig, by: 20, over: 0.4)
            let travel = rig.pointerTravel()
            XCTAssertGreaterThan(travel.net.x, 100, "seed \(seed)")
            XCTAssertLessThan(abs(travel.net.y), 0.3 * travel.net.x, "seed \(seed)")
            XCTAssertEqual(rig.count(.touchEnded), 0)
        }
    }

    /// Turning about the knuckles leaves the palm in place, so without the
    /// angle nothing would move.
    func testTurningInPlaceMovesThePointer() {
        let rig = pinched()
        turn(rig, by: 20, over: 0.4)
        XCTAssertGreaterThan(rig.pointerTravel().net.x, 50)
    }

    /// The engine's frame is mirrored like the preview, so +x is the user's
    /// right: turning the fingers to the right moves the pointer right.
    func testDirections() {
        let right = pinched { $0.pivotAtWrist = true }
        turn(right, by: 15, over: 0.4)
        XCTAssertGreaterThan(right.pointerTravel().net.x, 50, "turn right")

        let left = pinched { $0.pivotAtWrist = true }
        turn(left, by: -15, over: 0.4)
        XCTAssertLessThan(left.pointerTravel().net.x, -50, "turn left")

        let leaning = pinched { $0.pivotAtWrist = true; $0.tilt = 40 }
        turn(leaning, by: 15, over: 0.4)
        let lean = leaning.pointerTravel().net
        XCTAssertGreaterThan(lean.x, 50, "a leaning hand turning right still goes right")
        XCTAssertLessThan(abs(lean.y), 0.5 * lean.x)

    }

    /// Tipping the hand foreshortens the palm's length and so widens its
    /// width ratio, but it isn't a roll: vertically it moves only as far as
    /// the palm itself moves, as with the roll channel off.
    func testTippingTheHandIsNotARoll() {
        for seed in UInt64(1)...3 {
            for (from, to, name) in [(0.8, 1.0, "knuckles rising"), (1.0, 0.8, "knuckles falling")] {
                func travel(gain: Double) -> Vec2 {
                    let rig = pinched(seed: seed) { $0.foreshortening = from }
                    rig.engine.twist.config.gain = gain
                    tip(rig, to: to, over: 0.4)
                    return rig.pointerTravel().net
                }
                let with = travel(gain: ForearmTwistConfig().gain), without = travel(gain: 0)
                XCTAssertEqual(with.y, without.y, accuracy: 10, "seed \(seed): \(name)")
                XCTAssertLessThan(abs(with.y), 30, "seed \(seed): \(name)")
            }
        }
    }

    /// Turning at the wrist moves the knuckles as well as the angle; counting
    /// both would move the pointer `lever + 1` times the angle instead of
    /// `lever` times. It moves as far as sliding the hand that distance does.
    func testATurnAtTheWristCountsOnce() {
        let degrees = 20.0
        let lever = WristRotationConfig().lever
        let turned = pinched { $0.pivotAtWrist = true }
        turn(turned, by: degrees, over: 0.4)

        let slid = pinched()
        let distance = lever * degrees * .pi / 180 * slid.pose.size
        slid.move(by: Vec2(distance, 0), over: 0.4)
        slid.hold(0.2)

        let ratio = turned.pointerTravel().net.x / slid.pointerTravel().net.x
        XCTAssertEqual(ratio, 1, accuracy: 0.15, "turn \(turned.pointerTravel().net.x), slide \(slid.pointerTravel().net.x)")
    }

    func testSlidingWithoutTurningMovesAsBefore() {
        let withTurn = pinched()
        withTurn.move(by: Vec2(0.8 * withTurn.pose.size, -0.4 * withTurn.pose.size), over: 0.5)
        let without = pinched()
        without.engine.rotation.config.restRate = .infinity
        without.move(by: Vec2(0.8 * without.pose.size, -0.4 * without.pose.size), over: 0.5)
        let a = withTurn.pointerTravel().net, b = without.pointerTravel().net
        XCTAssertEqual(a.x, b.x, accuracy: 0.1 * abs(b.x))
        XCTAssertEqual(a.y, b.y, accuracy: 0.1 * abs(b.y))
    }

    func testStillNoisyHandDoesNotDrift() {
        for seed in UInt64(1)...6 {
            let rig = pinched(seed: seed)
            rig.hold(5)
            XCTAssertLessThan(rig.pointerTravel().path / 5, 1, "seed \(seed), points per second")
            XCTAssertEqual(rig.count(.touchEnded), 0)
        }
    }

    /// A resting hand sways a few degrees a second; like a slow creep in
    /// position, that stays below the rest speed.
    func testSlowSwayDoesNotDrift() {
        for seed in UInt64(1)...3 {
            let rig = pinched(seed: seed) { $0.pivotAtWrist = true }
            rig.run(5) { p, pose in pose.tilt = 3 * sin(p * 2 * .pi) }
            XCTAssertLessThan(rig.pointerTravel().path / 5, 1, "seed \(seed), points per second")
        }
    }

    func testTurningWithoutAPinchDoesNothing() {
        let rig = Rig.webcam(fps: 30)
        rig.hold(0.6)
        rig.run(2) { p, pose in pose.tilt = 25 * sin(p * 2 * .pi * 2) }
        rig.pose.pivotAtWrist = true
        rig.run(2) { p, pose in pose.tilt = 25 * sin(p * 2 * .pi * 2) }
        XCTAssertEqual(rig.pointerTravel().path, 0)
        XCTAssertTrue(rig.flings.isEmpty)
        XCTAssertEqual(rig.count(.touchBegan), 0)
    }

    func testTurningWithAFistScrollsAndNeverPoints() {
        let rig = Rig.webcam(fps: 30)
        rig.hold(0.6)
        rig.fist(true, over: 0.08)
        rig.hold(0.2)
        rig.pose.pivotAtWrist = true
        turn(rig, by: 25, over: 0.4)
        XCTAssertEqual(rig.count(.scrollBegan), 1)
        XCTAssertGreaterThan(rig.scrollTravel.length, 50, "a fist's turn is its roll")
        XCTAssertEqual(rig.pointerTravel().path, 0)
    }

    func testTurningDuringAQuickPinchStillClicksWhenSmall() {
        let rig = Rig.webcam(fps: 30)
        rig.hold(0.6)
        rig.pinch(true, over: 0.05)
        rig.run(0.1) { p, pose in pose.tilt = 2 * p }
        rig.pinch(false, over: 0.05)
        rig.hold(0.3)
        XCTAssertEqual(rig.clicks, [1])
    }
}
