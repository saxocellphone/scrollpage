import XCTest
@testable import ScrollpageCore

private let hu = HandPose().size

private extension Rig {
    /// Three-finger stroke of `delta` (image heights) at constant speed, the
    /// fingers parting at `releaseAt` (0...1) of the way, while still moving.
    func scrollFlick(by delta: Vec2, over duration: Double, releaseAt: Double = 0.8) {
        let start = pose.palm
        run(duration) { p, pose in
            pose.palm = start + delta * p
            if p >= releaseAt {
                pose.middleTouch = nil
                pose.pinchRatio = 0.8
            }
        }
    }

    func outputsAfter(_ match: (GestureOutput) -> Bool) -> [GestureOutput] {
        let all = outputs.map(\.output)
        guard let i = all.lastIndex(where: match) else { return [] }
        return Array(all[(i + 1)...])
    }
}

final class ThreeFingerScrollTests: XCTestCase {
    private func scroll(_ delta: Vec2, settings: MotionSettings = MotionSettings(), over duration: Double = 0.5) -> Rig {
        let rig = Rig(settings: settings)
        rig.hold(0.5)
        rig.threeFinger(true)
        rig.hold(0.1)
        rig.move(by: delta, over: duration)
        rig.hold(0.3)
        rig.threeFinger(false)
        rig.hold(0.5)
        return rig
    }

    func testContentFollowsTheHandOneToOne() {
        let rig = scroll(Vec2(0, -0.5 * hu))
        let gain = MotionSettings().scrollGain
        XCTAssertEqual(gain, 500, accuracy: 1e-9)
        XCTAssertEqual(rig.scrollTravel.y, -0.5 * gain, accuracy: 0.1 * 0.5 * gain, "natural: hand up moves content up")
        XCTAssertLessThan(abs(rig.scrollTravel.x), 5)
        XCTAssertEqual(rig.count(.scrollBegan), 1)
        XCTAssertEqual(rig.scrollEnds, [.zero], "held still before lifting: no glide")
        XCTAssertTrue(rig.flings.isEmpty)
    }

    func testNoPointerOutputDuringAScroll() {
        let rig = scroll(Vec2(0.4 * hu, -0.5 * hu))
        XCTAssertEqual(rig.pointerTravel().path, 0)
        XCTAssertEqual(rig.count(.touchBegan), 0)
        XCTAssertEqual(rig.count(.pressBegan), 0)
        XCTAssertTrue(rig.clicks.isEmpty)
    }

    func testOutputOrder() {
        let rig = scroll(Vec2(0, 0.5 * hu))
        let kinds = rig.outputs.map(\.output).map { o -> String in
            switch o {
            case .scrollBegan: "began"
            case .scrolled: "scrolled"
            case .scrollEnded: "ended"
            default: "other"
            }
        }
        XCTAssertEqual(kinds.first, "began")
        XCTAssertEqual(kinds.last, "ended")
        XCTAssertGreaterThan(kinds.filter { $0 == "scrolled" }.count, 10)
        XCTAssertFalse(kinds.contains("other"))
    }

    func testNaturalScrollingOff() {
        let rig = scroll(Vec2(0, -0.5 * hu), settings: MotionSettings(naturalScrolling: false))
        XCTAssertEqual(rig.scrollTravel.y, 0.5 * 500, accuracy: 25)
    }

    func testHorizontalScroll() {
        let rig = scroll(Vec2(0.5 * hu, 0))
        XCTAssertEqual(rig.scrollTravel.x, 0.5 * 500, accuracy: 25)
        XCTAssertLessThan(abs(rig.scrollTravel.y), 5)
    }

    func testScrollingSpeedScalesTheMapping() {
        let slow = scroll(Vec2(0, 0.5 * hu), settings: MotionSettings(scrollingSpeed: 0)).scrollTravel.y
        let fast = scroll(Vec2(0, 0.5 * hu), settings: MotionSettings(scrollingSpeed: 1)).scrollTravel.y
        XCTAssertEqual(slow, 0.5 * 250, accuracy: 15)
        XCTAssertEqual(fast / slow, 4, accuracy: 0.3)
    }

    func testSlowScrollIsPreciseNotAccelerated() {
        let slow = scroll(Vec2(0, 0.4 * hu), over: 2.0).scrollTravel.y
        let fast = scroll(Vec2(0, 0.4 * hu), over: 0.25).scrollTravel.y
        XCTAssertEqual(slow, 0.4 * 500, accuracy: 0.15 * 0.4 * 500)
        XCTAssertEqual(fast, slow, accuracy: 0.1 * slow, "the same hand travel scrolls the same distance")
    }

    func testStillHandDoesNotCreepOnAWebcam() {
        for seed in UInt64(1)...5 {
            let rig = Rig.webcam(seed: seed, fps: 30)
            rig.hold(0.5)
            rig.threeFinger(true, over: 0.07)
            rig.hold(0.3)
            let start = rig.t
            rig.hold(3)
            let creep = rig.outputs.filter { $0.t > start }.reduce(0.0) {
                if case let .scrolled(dx, dy) = $1.output { return $0 + Vec2(dx, dy).length }
                return $0
            }
            XCTAssertEqual(rig.count(.scrollBegan), 1, "seed \(seed)")
            XCTAssertLessThan(creep, 10, "seed \(seed): crept \(creep) pt in 3 s")
        }
    }

    func testWebcamScrollFollowsTheHand() {
        for seed in UInt64(1)...5 {
            let rig = Rig.webcam(seed: seed, fps: 30)
            let u = rig.pose.size
            rig.hold(0.5)
            rig.threeFinger(true, over: 0.07)
            rig.hold(0.2)
            rig.move(by: Vec2(0, 0.6 * u), over: 0.6)
            rig.hold(0.3)
            rig.threeFinger(false, over: 0.07)
            rig.hold(0.3)
            XCTAssertEqual(rig.scrollTravel.y, 0.6 * 500, accuracy: 0.15 * 0.6 * 500, "seed \(seed)")
            XCTAssertEqual(rig.pointerTravel().path, 0, "seed \(seed)")
            XCTAssertEqual(rig.count(.scrollBegan), 1, "seed \(seed)")
            XCTAssertEqual(rig.scrollEnds.count, 1, "seed \(seed)")
        }
    }
}

final class ScrollMomentumTests: XCTestCase {
    func testQuickReleaseGlidesAtTheHandsSpeed() {
        let rig = Rig()
        rig.hold(0.5)
        rig.threeFinger(true)
        rig.hold(0.1)
        rig.scrollFlick(by: Vec2(0, -0.6 * hu), over: 0.4)
        rig.hold(0.5)
        XCTAssertEqual(rig.scrollEnds.count, 1)
        let v = rig.scrollEnds[0]
        let handSpeed = 0.6 / 0.4 * 500
        XCTAssertLessThan(v.y, 0, "glides the way the content moved")
        XCTAssertEqual(-v.y, handSpeed, accuracy: 0.35 * handSpeed)
        XCTAssertLessThan(abs(v.x), 0.1 * handSpeed)
        XCTAssertEqual(rig.pointerTravel().path, 0)
    }

    func testSlowReleaseDoesNotGlide() {
        let rig = Rig()
        rig.hold(0.5)
        rig.threeFinger(true)
        rig.hold(0.1)
        rig.scrollFlick(by: Vec2(0, -0.05 * hu), over: 0.5)
        rig.hold(0.3)
        XCTAssertEqual(rig.scrollEnds, [.zero])
    }

    func testANewTouchCatchesTheGlide() {
        let rig = Rig()
        rig.hold(0.5)
        rig.threeFinger(true)
        rig.hold(0.1)
        rig.scrollFlick(by: Vec2(0, -0.6 * hu), over: 0.4)
        rig.hold(0.15)
        rig.pinch(true)
        rig.hold(0.05)
        XCTAssertEqual(rig.outputsAfter { if case .scrollEnded = $0 { true } else { false } }.prefix(2),
                       [.catchGlide, .touchBegan])
    }

    func testANewScrollCatchesTheGlide() {
        let rig = Rig()
        rig.hold(0.5)
        rig.threeFinger(true)
        rig.hold(0.1)
        rig.scrollFlick(by: Vec2(0, -0.6 * hu), over: 0.4)
        rig.hold(0.1)
        rig.threeFinger(true)
        rig.hold(0.05)
        XCTAssertEqual(rig.outputsAfter { if case .scrollEnded = $0 { true } else { false } }.prefix(2),
                       [.catchGlide, .scrollBegan])
    }

    func testLosingTheHandEndsTheScrollWithoutAGlide() {
        let rig = Rig()
        rig.hold(0.5)
        rig.threeFinger(true)
        rig.hold(0.1)
        let start = rig.pose.palm
        rig.run(0.2) { p, pose in pose.palm = start + Vec2(0, -0.4 * hu * p) }
        rig.run(0.4, visible: false)
        XCTAssertEqual(rig.scrollEnds, [.zero])
        XCTAssertFalse(rig.engine.snapshot.isScrolling)
    }
}

final class TouchKindLockTests: XCTestCase {
    func testPinchDoesNotTurnIntoAScroll() {
        let rig = Rig()
        rig.hold(0.5)
        rig.pinch(true)
        rig.move(by: Vec2(0.3 * hu, 0), over: 0.3)
        rig.pose.middleTouch = Rig.touching
        rig.move(by: Vec2(0.3 * hu, 0), over: 0.3)
        XCTAssertTrue(rig.engine.snapshot.isTouching)
        XCTAssertFalse(rig.engine.snapshot.isScrolling)
        rig.pose.middleTouch = nil
        rig.pinch(false)
        rig.hold(0.3)
        XCTAssertEqual(rig.count(.scrollBegan), 0)
        XCTAssertTrue(rig.scrolls.isEmpty)
        XCTAssertGreaterThan(rig.pointerTravel().net.x, 100)
    }

    func testScrollDoesNotTurnIntoAPinch() {
        let rig = Rig()
        rig.hold(0.5)
        rig.threeFinger(true)
        rig.move(by: Vec2(0, 0.3 * hu), over: 0.3)
        XCTAssertTrue(rig.engine.snapshot.isScrolling)
        rig.pose.middleTouch = nil
        rig.move(by: Vec2(0.4 * hu, 0), over: 0.4)
        rig.pinch(false)
        rig.hold(0.3)
        XCTAssertEqual(rig.count(.scrollBegan), 1)
        XCTAssertEqual(rig.scrollEnds.count, 1)
        XCTAssertEqual(rig.count(.touchBegan), 0)
        XCTAssertEqual(rig.pointerTravel().path, 0)
        XCTAssertTrue(rig.clicks.isEmpty)
    }

    func testScrollSnapshot() {
        let rig = Rig()
        rig.hold(0.5)
        rig.threeFinger(true)
        rig.hold(0.1)
        XCTAssertTrue(rig.engine.snapshot.isScrolling)
        XCTAssertFalse(rig.engine.snapshot.isTouching)
        XCTAssertTrue(rig.engine.isEngaged)
        rig.threeFinger(false)
        rig.hold(0.1)
        XCTAssertFalse(rig.engine.snapshot.isScrolling)
        XCTAssertFalse(rig.engine.isEngaged)
    }
}
