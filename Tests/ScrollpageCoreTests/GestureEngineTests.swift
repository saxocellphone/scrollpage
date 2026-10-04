import XCTest
@testable import ScrollpageCore

/// One hand unit of palm motion, in image-height units, for the default synthetic hand.
private let hu = HandPose().size

final class GestureEnginePointerTests: XCTestCase {
    func testStillPinchedHandDoesNotDrift() {
        let rig = Rig()
        rig.hold(0.5)
        rig.pinch(true)
        rig.move(by: Vec2(0.5 * hu, 0.2 * hu), over: 0.5)
        rig.hold(1.0)
        let start = rig.t
        rig.hold(3.0)
        let drift = rig.pointerTravel(since: start).path / 3.0
        XCTAssertLessThan(drift, 1.0, "drift \(drift) pt/s")
    }

    func testOpenHandNeverMovesThePointer() {
        let rig = Rig()
        rig.hold(0.3)
        rig.move(by: Vec2(1.0 * hu, 0), over: 0.6)
        rig.hold(0.3)
        XCTAssertEqual(rig.pointerTravel().path, 0)
        XCTAssertEqual(rig.count(.touchBegan), 0)
    }

    func testPinchAndMoveMovesWithoutClicking() {
        let rig = Rig()
        rig.hold(0.5)
        rig.pinch(true)
        rig.move(by: Vec2(0.6 * hu, 0), over: 0.5)
        rig.pinch(false)
        rig.hold(0.3)
        XCTAssertTrue(rig.clicks.isEmpty)
        XCTAssertGreaterThan(rig.pointerTravel().net.x, 100)
        XCTAssertEqual(rig.count(.touchBegan), 1)
        XCTAssertEqual(rig.count(.touchEnded), 1)
    }

    func testSlowMoveIsPreciseAndFastSweepCrossesTheScreen() {
        let slow = Rig()
        slow.hold(0.5)
        slow.pinch(true)
        slow.move(by: Vec2(0.5 * hu, 0), over: 2.0)
        slow.hold(0.5)
        let slowTravel = slow.pointerTravel().net.x

        let fast = Rig()
        fast.hold(0.5)
        fast.pinch(true)
        fast.move(by: Vec2(1.0 * hu, 0), over: 0.2)
        fast.hold(0.5)
        let fastTravel = fast.pointerTravel().net.x

        XCTAssertLessThan(slowTravel, 0.5 * 165 * 1.3, "slow 0.5 hu moved \(slowTravel) pt")
        XCTAssertGreaterThan(slowTravel, 20)
        XCTAssertGreaterThanOrEqual(fastTravel, 1512, "fast 1 hu sweep moved \(fastTravel) pt")
    }

    func testDirectionFollowsTheHand() {
        let rig = Rig()
        rig.hold(0.5)
        rig.pinch(true)
        rig.move(by: Vec2(-0.3 * hu, 0.4 * hu), over: 0.4)
        rig.hold(0.3)
        let net = rig.pointerTravel().net
        XCTAssertLessThan(net.x, 0)
        XCTAssertGreaterThan(net.y, 0, "hand down moves the pointer down (y-down)")
    }
}

final class GestureEngineClickTests: XCTestCase {
    private func tap(_ rig: Rig) {
        rig.pinch(true)
        rig.hold(0.08)
        rig.pinch(false)
    }

    func testQuickTapClicksOnceWithoutMoving() {
        let rig = Rig()
        rig.hold(0.5)
        tap(rig)
        rig.hold(0.5)
        XCTAssertEqual(rig.clicks, [1])
        XCTAssertEqual(rig.pointerTravel().path, 0)
        let order = rig.outputs.map(\.output)
        XCTAssertEqual(order, [.touchBegan, .click(count: 1), .touchEnded])
    }

    func testTapWithSmallWobbleStillClicksWithoutMoving() {
        let rig = Rig()
        rig.hold(0.5)
        rig.pinch(true)
        rig.move(by: Vec2(0.04 * hu, -0.03 * hu), over: 0.1)
        rig.pinch(false)
        rig.hold(0.3)
        XCTAssertEqual(rig.clicks, [1])
        XCTAssertEqual(rig.pointerTravel().path, 0)
    }

    func testDoubleAndTripleTap() {
        let rig = Rig()
        rig.hold(0.5)
        tap(rig); rig.hold(0.15)
        tap(rig); rig.hold(0.15)
        tap(rig); rig.hold(0.6)
        tap(rig)
        XCTAssertEqual(rig.clicks, [1, 2, 3, 1])
    }

    func testSlowTapsAreSeparateClicks() {
        let rig = Rig()
        rig.hold(0.5)
        tap(rig); rig.hold(0.7)
        tap(rig)
        XCTAssertEqual(rig.clicks, [1, 1])
    }

    func testHeldPinchIsNotAClick() {
        let rig = Rig()
        rig.hold(0.5)
        rig.pinch(true)
        rig.hold(0.45)
        rig.pinch(false)
        XCTAssertTrue(rig.clicks.isEmpty)
        XCTAssertEqual(rig.count(.pressBegan), 0)
    }

    func testLongPressThenMoveDrags() {
        let rig = Rig()
        rig.hold(0.5)
        rig.pinch(true)
        rig.hold(0.8)
        XCTAssertEqual(rig.count(.pressBegan), 1)
        let pressedAt = rig.t
        rig.move(by: Vec2(0.5 * hu, 0), over: 0.5)
        rig.pinch(false)
        rig.hold(0.3)
        XCTAssertGreaterThan(rig.pointerTravel(since: pressedAt).net.x, 40)
        XCTAssertTrue(rig.clicks.isEmpty)
        let kinds = rig.outputs.map(\.output).filter {
            if case .pointerMoved = $0 { return false } else { return true }
        }
        XCTAssertEqual(kinds, [.touchBegan, .pressBegan, .touchEnded])
    }

    func testLosingTheHandMidPinchEndsWithoutClick() {
        let rig = Rig()
        rig.hold(0.5)
        rig.pinch(true)
        rig.hold(0.05)
        rig.run(0.4, visible: false)
        XCTAssertTrue(rig.clicks.isEmpty)
        XCTAssertEqual(rig.count(.touchEnded), 1)
        XCTAssertFalse(rig.engine.snapshot.isTouching)
    }

    func testShortTrackingGapIsBridged() {
        let rig = Rig()
        rig.hold(0.5)
        rig.pinch(true)
        rig.hold(0.03)
        rig.run(0.08, visible: false)
        rig.hold(0.03)
        rig.pinch(false)
        XCTAssertEqual(rig.count(.touchBegan), 1)
        XCTAssertEqual(rig.clicks, [1])
    }
}

final class GestureEngineFlickTests: XCTestCase {
    private func flick(_ rig: Rig, dy: Double, over duration: Double = 0.12) {
        rig.move(by: Vec2(0, dy * hu), over: duration)
    }

    func testOpenHandFlickUpScrollsNaturally() {
        let rig = Rig()
        rig.hold(0.5)
        flick(rig, dy: -0.6)
        rig.hold(0.5)
        XCTAssertEqual(rig.flings.count, 1)
        let v = rig.flings[0]
        XCTAssertLessThan(v.y, -500, "natural: hand up moves content up")
        XCTAssertEqual(v.x, 0)
        XCTAssertEqual(rig.pointerTravel().path, 0)
    }

    func testFlickReversedWithoutNaturalScrolling() {
        let rig = Rig(settings: MotionSettings(naturalScrolling: false))
        rig.hold(0.5)
        flick(rig, dy: -0.6)
        rig.hold(0.5)
        XCTAssertEqual(rig.flings.count, 1)
        XCTAssertGreaterThan(rig.flings[0].y, 500)
    }

    func testHorizontalFlick() {
        let rig = Rig()
        rig.hold(0.5)
        rig.move(by: Vec2(0.6 * hu, 0), over: 0.12)
        rig.hold(0.5)
        XCTAssertEqual(rig.flings.count, 1)
        XCTAssertGreaterThan(rig.flings[0].x, 500)
        XCTAssertEqual(rig.flings[0].y, 0)
    }

    func testScrollingSpeedScalesFling() {
        func velocity(_ s: Double) -> Double {
            let rig = Rig(settings: MotionSettings(scrollingSpeed: s))
            rig.hold(0.5)
            rig.move(by: Vec2(0, -0.6 * hu), over: 0.12)
            rig.hold(0.5)
            return rig.flings.first.map { abs($0.y) } ?? 0
        }
        XCTAssertGreaterThan(velocity(1), velocity(0) * 3)
    }

    func testFasterFlickFlingsFaster() {
        func velocity(_ duration: Double) -> Double {
            let rig = Rig()
            rig.hold(0.5)
            rig.move(by: Vec2(0, -0.6 * hu), over: duration)
            rig.hold(0.5)
            return rig.flings.first.map { abs($0.y) } ?? 0
        }
        XCTAssertGreaterThan(velocity(0.09), velocity(0.15))
        XCTAssertGreaterThan(velocity(0.15), 0)
    }

    func testReturnStrokeIsIgnored() {
        let rig = Rig()
        rig.hold(0.5)
        flick(rig, dy: -0.6)
        rig.hold(0.1)
        flick(rig, dy: 0.6, over: 0.15)
        rig.hold(0.8)
        XCTAssertEqual(rig.flings.count, 1)
        flick(rig, dy: 0.6)
        rig.hold(0.3)
        XCTAssertEqual(rig.flings.count, 2, "a deliberate flick back later counts")
        XCTAssertGreaterThan(rig.flings[1].y, 0)
    }

    func testSlowMotionAndSweepsDoNotFling() {
        let rig = Rig()
        rig.hold(0.5)
        flick(rig, dy: -1.0, over: 1.0)
        rig.hold(0.3)
        flick(rig, dy: 1.5, over: 0.6)
        rig.hold(0.3)
        XCTAssertTrue(rig.flings.isEmpty)
    }

    func testClosedHandDoesNotFling() {
        let rig = Rig()
        rig.pose.fingersOpen = false
        rig.hold(0.5)
        flick(rig, dy: -0.6)
        rig.hold(0.5)
        XCTAssertTrue(rig.flings.isEmpty)
    }

    func testHandEnteringTheFrameFastDoesNotFling() {
        let rig = Rig()
        rig.run(0.5, visible: false)
        let speed = 5.0 * hu
        rig.run(0.2) { _, pose in pose.palm.y -= speed / 60 }
        rig.hold(0.5)
        XCTAssertTrue(rig.flings.isEmpty)
    }

    func testMotionAfterPinchReleaseDoesNotFling() {
        let rig = Rig()
        rig.hold(0.5)
        rig.pinch(true)
        let start = rig.pose.palm
        rig.run(0.5) { p, pose in
            let s = p * p * p * (10 - 15 * p + 6 * p * p)
            pose.palm = start + Vec2(0, -1.2 * hu * s)
            if p > 0.4 { pose.pinchRatio = 0.8 }
        }
        rig.hold(0.5)
        XCTAssertTrue(rig.flings.isEmpty)
        XCTAssertEqual(rig.count(.touchEnded), 1)
    }

    func testPinchTapAfterFlickClicks() {
        let rig = Rig()
        rig.hold(0.5)
        flick(rig, dy: -0.6)
        rig.hold(0.3)
        rig.pinch(true)
        rig.hold(0.05)
        rig.pinch(false)
        XCTAssertEqual(rig.flings.count, 1)
        XCTAssertEqual(rig.clicks, [1])
        let afterFling = rig.outputs.drop { if case .fling = $0.output { return false } else { return true } }
        XCTAssertEqual(afterFling.dropFirst().first?.output, .touchBegan)
    }
}
