import XCTest
@testable import ScrollpageCore

private let hu = HandPose().size

private extension Rig {
    /// Opens the fist at `releaseAt` (0...1) of a stroke of `delta` (image
    /// heights) at constant speed, while still moving.
    func scrollFlick(by delta: Vec2, over duration: Double, releaseAt: Double = 0.8) {
        let start = pose.palm
        run(duration) { p, pose in
            pose.palm = start + delta * p
            if p >= releaseAt {
                pose.fingersOpen = true
                pose.thumbTucked = false
            }
        }
    }

    func outputsAfter(_ match: (GestureOutput) -> Bool) -> [GestureOutput] {
        let all = outputs.map(\.output)
        guard let i = all.lastIndex(where: match) else { return [] }
        return Array(all[(i + 1)...])
    }

    /// Content displacement over the outputs since `t`.
    func scrollTravel(since t: Double) -> Vec2 {
        outputs.filter { $0.t > t }.reduce(.zero) {
            if case let .scrolled(dx, dy) = $1.output { return $0 + Vec2(dx, dy) }
            return $0
        }
    }
}

/// Recognizing the fist, against the poses that come close to it.
final class FistDetectorTests: XCTestCase {
    private var gen = SyntheticHand(sigma: 0, touchSigma: 0)
    private var detector = FistDetector()
    private var t = 0.0

    @discardableResult
    private func frames(_ n: Int, _ pose: HandPose, speed: Double = 0, canStart: Bool = true) -> [FistEvent] {
        (0..<n).compactMap { _ in
            t += 1.0 / 30
            return detector.update(gen.sample(pose), handSize: pose.size, speed: speed, canStart: canStart, at: t)
        }
    }

    func testAFistBeginsAfterConfirmationAndEndsWhenTheHandOpens() {
        frames(5, HandPose())
        XCTAssertEqual(frames(2, .fist), [])
        let begun = frames(4, .fist)
        XCTAssertEqual(begun, [.began])
        XCTAssertTrue(detector.active)
        XCTAssertEqual(frames(30, .fist), [], "held")
        XCTAssertEqual(frames(4, HandPose()), [.ended(opened: true)])
        XCTAssertFalse(detector.active)
        XCTAssertEqual(frames(6, .fist), [.began], "the open hand re-arms it")
    }

    /// The finger tracker flips the fingers on the second frame, which is the
    /// first of three the fist needs: 0.13 s at 30 fps, so a hand passing
    /// through a fist on its way somewhere doesn't scroll.
    func testConfirmationTakesFourFramesFromOpen() {
        frames(5, HandPose())
        XCTAssertEqual(frames(3, .fist), [])
        XCTAssertTrue(detector.isEngaged, "being confirmed")
        XCTAssertEqual(frames(1, .fist), [.began])
    }

    func testAHandThatArrivesClosedNeverScrolls() {
        XCTAssertEqual(frames(60, .fist), [])
    }

    func testAFistClosedOnTheMoveWaitsUntilItSlows() {
        frames(5, HandPose())
        XCTAssertEqual(frames(20, .fist, speed: 2.5), [], "a hand closing on its way somewhere")
        XCTAssertEqual(frames(3, .fist, speed: 1.0), [.began])
    }

    func testAnotherGestureUnderWayBlocksIt() {
        frames(5, HandPose())
        XCTAssertEqual(frames(20, .fist, canStart: false), [])
        XCTAssertEqual(frames(3, .fist), [.began])
    }

    func testNearMissesNeverStart() {
        var loose = HandPose()
        loose.curl = [.indexMCP: 0.75, .middleMCP: 0.75, .ringMCP: 0.75, .littleMCP: 0.75]
        var relaxed = HandPose()
        relaxed.curl = [.indexMCP: 0.4, .middleMCP: 0.4, .ringMCP: 0.4, .littleMCP: 0.4]
        var curledPinch = HandPose.fist
        curledPinch.thumbTucked = false
        curledPinch.thumbOn = .indexTip
        var pointing = HandPose.fist
        pointing.fingersOpen = true
        pointing.folded = [.middleMCP, .ringMCP, .littleMCP]
        var hiddenTips = HandPose.fist
        hiddenTips.hidden = [.indexTip, .middleTip, .ringTip, .littleTip]
        let cases: [(String, HandPose)] = [
            ("open hand", HandPose()),
            ("relaxed, fingers bent", relaxed),
            ("loosely curled, between the tolerances", loose),
            ("pinch with the other fingers curled in", curledPinch),
            ("one finger pointing", pointing),
            ("peace sign", .peaceSign),
            ("fingertips out of view", hiddenTips),
        ]
        for (name, pose) in cases {
            var d = FistDetector()
            var t = 0.0
            var events: [FistEvent] = []
            for i in 0..<90 {
                t += 1.0 / 30
                let p = i < 10 ? HandPose() : pose
                if let e = d.update(gen.sample(p), handSize: p.size, speed: 0, at: t) { events.append(e) }
            }
            XCTAssertEqual(events, [], name)
        }
    }

    /// Rolled palm down, the thumb tip lands on the index tip in the image:
    /// that only matters for starting.
    func testThumbOnTheIndexTipDoesntEndAFist() {
        frames(5, HandPose())
        frames(6, .fist)
        var rolled = HandPose.fist
        rolled.thumbTucked = false
        rolled.thumbOn = .indexTip
        XCTAssertEqual(frames(20, rolled), [])
        XCTAssertTrue(detector.active)
    }

    func testOneFingerOpeningHoldsTheFist() {
        frames(5, HandPose())
        frames(6, .fist)
        var one = HandPose.fist
        one.fingersOpen = true
        one.folded = [.middleMCP, .ringMCP, .littleMCP]
        one.curl = [.indexMCP: 0.5]
        XCTAssertEqual(frames(10, one), [])
        XCTAssertTrue(detector.active)
    }

    func testHiddenFingertipsHoldBrieflyThenGiveUp() {
        frames(5, HandPose())
        frames(6, .fist)
        var hidden = HandPose.fist
        hidden.hidden = [.littleTip]
        XCTAssertEqual(frames(8, hidden), [], "0.27 s")
        XCTAssertEqual(frames(4, hidden), [.ended(opened: false)])
    }
}

final class FistScrollTests: XCTestCase {
    private func fistRig(settings: MotionSettings = MotionSettings()) -> Rig {
        let rig = Rig(settings: settings)
        rig.hold(0.5)
        rig.fist(true)
        rig.hold(0.15)
        return rig
    }

    private func scroll(_ delta: Vec2, settings: MotionSettings = MotionSettings(), over duration: Double = 0.5) -> Rig {
        let rig = fistRig(settings: settings)
        rig.move(by: delta, over: duration)
        rig.hold(0.3)
        rig.fist(false)
        rig.hold(0.5)
        return rig
    }

    private func roll(_ degrees: Double, settings: MotionSettings = MotionSettings(), over duration: Double = 0.5) -> Rig {
        let rig = fistRig(settings: settings)
        rig.roll(by: degrees, over: duration)
        rig.hold(0.3)
        return rig
    }

    func testMovingTheFistScrollsWithIt() {
        let gain = MotionSettings().scrollGain
        XCTAssertEqual(gain, 500, accuracy: 1e-9)
        let side = scroll(Vec2(0.5 * hu, 0))
        XCTAssertGreaterThan(side.scrollTravel.x, 0.5 * gain * FistScrollConfig().slowGain, "natural: content follows the hand")
        XCTAssertLessThan(side.scrollTravel.x, 0.5 * gain * FistScrollConfig().fastGain)
        XCTAssertLessThan(abs(side.scrollTravel.y), 0.05 * side.scrollTravel.x)
        XCTAssertEqual(side.count(.scrollBegan), 1)
        XCTAssertEqual(side.scrollEnds, [.zero], "held still before opening: no glide")
        XCTAssertTrue(side.flings.isEmpty)

        let up = scroll(Vec2(0, -0.5 * hu))
        XCTAssertLessThan(up.scrollTravel.y, 0, "hand up moves the content up")
        XCTAssertLessThan(abs(up.scrollTravel.x), 0.05 * abs(up.scrollTravel.y))
        let ratio = abs(up.scrollTravel.y) / side.scrollTravel.x
        XCTAssertLessThan(ratio, 0.6, "up and down, moving the hand counts half: the roll is the vertical")
        XCTAssertGreaterThan(ratio, 0.2)
    }

    /// Palm toward the ceiling turns the edge-on fist clockwise on screen and
    /// scrolls like fingers moving up the pad; palm toward the floor, down.
    func testRollingScrollsVertically() {
        let up = roll(20)
        XCTAssertLessThan(up.scrollTravel.y, -50)
        XCTAssertLessThan(abs(up.scrollTravel.x), 0.15 * abs(up.scrollTravel.y), "the wrist stays put")
        let down = roll(-30)
        XCTAssertGreaterThan(down.scrollTravel.y, 50)
        XCTAssertLessThan(abs(down.scrollTravel.x), 0.15 * down.scrollTravel.y)
        for rig in [up, down] {
            XCTAssertEqual(rig.pointerTravel().path, 0)
            XCTAssertEqual(rig.count(.touchBegan), 0)
        }
    }

    /// Each direction is scaled to its own range (the fist turns about 32
    /// degrees palm up and 75 palm down at a full roll), so a full roll either
    /// way scrolls as far.
    func testAFullRollEitherWayScrollsAsFar() {
        let c = FistScrollConfig()
        let up = roll(c.upRange * 180 / .pi, over: 0.6).scrollTravel.y
        let down = roll(-c.downRange * 180 / .pi, over: 0.6).scrollTravel.y
        XCTAssertLessThan(up, 0)
        XCTAssertEqual(-up, down, accuracy: 0.2 * down, "up \(up), down \(down)")
    }

    /// A fist closed mid-roll, palm partly down, that rolls back to rest is
    /// moving back across the palm-down range.
    func testAFistClosedMidRollScalesBackToRestByItsSide() {
        let c = FistScrollConfig()
        let degrees = c.downRange * 0.5 * 180 / .pi
        let rig = Rig()
        rig.hold(0.5)
        rig.roll(by: -degrees, over: 0.5)
        rig.hold(0.15)
        rig.fist(true)
        rig.hold(0.15)
        let start = rig.t
        rig.roll(by: degrees, over: 0.5)
        rig.hold(0.3)
        let back = rig.scrollTravel(since: start).y

        let fromRest = roll(-degrees, over: 0.5).scrollTravel.y
        XCTAssertLessThan(back, 0, "rolling back up scrolls up")
        XCTAssertEqual(-back, fromRest, accuracy: 0.3 * fromRest, "back \(back), out \(fromRest)")
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

    func testNaturalScrollingOffFlipsEveryDirection() {
        let off = MotionSettings(naturalScrolling: false)
        XCTAssertEqual(scroll(Vec2(0, -0.5 * hu), settings: off).scrollTravel.y,
                       -scroll(Vec2(0, -0.5 * hu)).scrollTravel.y, accuracy: 1e-6)
        XCTAssertEqual(scroll(Vec2(0.5 * hu, 0), settings: off).scrollTravel.x,
                       -scroll(Vec2(0.5 * hu, 0)).scrollTravel.x, accuracy: 1e-6)
        XCTAssertGreaterThan(roll(20, settings: off).scrollTravel.y, 50, "palm up scrolls the other way")
    }

    func testScrollingSpeedScalesTheMapping() {
        let slow = scroll(Vec2(0, 0.5 * hu), settings: MotionSettings(scrollingSpeed: 0)).scrollTravel.y
        let fast = scroll(Vec2(0, 0.5 * hu), settings: MotionSettings(scrollingSpeed: 1)).scrollTravel.y
        XCTAssertEqual(fast / slow, 4, accuracy: 0.01)
    }

    /// Slow here is deliberate, 0.5 hand units a second on average: slower
    /// than about 0.3 a fist is held still (`FistScrollConfig.restSpeed`).
    func testQuickMotionScrollsFartherThanSlow() {
        let slow = scroll(Vec2(0.4 * hu, 0), over: 0.8).scrollTravel.x
        let fast = scroll(Vec2(0.4 * hu, 0), over: 0.2).scrollTravel.x
        XCTAssertGreaterThan(fast, 1.5 * slow, "the pointer's acceleration curve")
        XCTAssertGreaterThan(slow, 0.4 * 500 * FistScrollConfig().slowGain * 0.7)
    }

    func testStillFistDoesNotCreepOnAWebcam() {
        for seed in UInt64(1)...5 {
            let rig = Rig.webcam(seed: seed, fps: 30)
            rig.hold(0.5)
            rig.fist(true, over: 0.07)
            rig.hold(0.3)
            let start = rig.t
            rig.hold(3)
            let creep = rig.outputs.filter { $0.t > start }.reduce(0.0) {
                if case let .scrolled(dx, dy) = $1.output { return $0 + Vec2(dx, dy).length }
                return $0
            }
            XCTAssertEqual(rig.count(.scrollBegan), 1, "seed \(seed)")
            XCTAssertLessThan(creep / 3, 1, "seed \(seed): crept \(creep) pt in 3 s")
        }
    }

    func testWebcamScrollFollowsTheHand() {
        for seed in UInt64(1)...5 {
            let rig = Rig.webcam(seed: seed, fps: 30)
            let u = rig.pose.size
            rig.hold(0.5)
            rig.fist(true, over: 0.07)
            rig.hold(0.2)
            rig.move(by: Vec2(0, 0.6 * u), over: 0.6)
            rig.hold(0.3)
            rig.fist(false, over: 0.07)
            rig.hold(0.3)
            XCTAssertGreaterThan(rig.scrollTravel.y, 0.6 * 0.5 * 500 * FistScrollConfig().slowGain, "seed \(seed)")
            XCTAssertEqual(rig.pointerTravel().path, 0, "seed \(seed)")
            XCTAssertEqual(rig.count(.scrollBegan), 1, "seed \(seed)")
            XCTAssertEqual(rig.scrollEnds.count, 1, "seed \(seed)")
        }
    }
}

final class FistMomentumTests: XCTestCase {
    private func flick(by delta: Vec2 = Vec2(-0.8 * hu, 0)) -> (rig: Rig, releasedAt: Double) {
        let rig = Rig()
        rig.hold(0.5)
        rig.fist(true)
        rig.hold(0.15)
        rig.scrollFlick(by: delta, over: 0.4)
        let released = rig.outputs.first { if case .scrollEnded = $0.output { return true } else { return false } }?.t ?? rig.t
        rig.hold(0.5)
        return (rig, released)
    }

    func testQuickReleaseGlidesAShareOfTheContentSpeed() {
        let (rig, released) = flick()
        XCTAssertEqual(rig.scrollEnds.count, 1)
        let v = rig.scrollEnds[0]
        let recent = rig.outputs.filter { $0.t > released - 0.1 && $0.t < released }
        let speed = recent.reduce(Vec2.zero) {
            if case let .scrolled(dx, dy) = $1.output { return $0 + Vec2(dx, dy) }
            return $0
        } / 0.1
        XCTAssertLessThan(v.x, 0, "glides the way the content moved")
        XCTAssertEqual(-v.x, -speed.x * FistScrollConfig().glide, accuracy: 0.35 * -speed.x * FistScrollConfig().glide)
        XCTAssertLessThan(abs(v.y), 0.1 * abs(v.x))
        XCTAssertEqual(rig.pointerTravel().path, 0)
    }

    func testSlowReleaseDoesNotGlide() {
        let rig = Rig()
        rig.hold(0.5)
        rig.fist(true)
        rig.hold(0.15)
        rig.scrollFlick(by: Vec2(-0.05 * hu, 0), over: 0.5)
        rig.hold(0.3)
        XCTAssertEqual(rig.scrollEnds, [.zero])
    }

    func testAPinchCatchesTheGlide() {
        let (rig, _) = flick()
        rig.pinch(true)
        rig.hold(0.05)
        XCTAssertEqual(rig.outputsAfter { if case .scrollEnded = $0 { true } else { false } }.prefix(2),
                       [.catchGlide, .touchBegan])
    }

    func testANewFistCatchesTheGlide() {
        let (rig, _) = flick()
        rig.fist(true)
        rig.hold(0.15)
        XCTAssertEqual(rig.outputsAfter { if case .scrollEnded = $0 { true } else { false } }.prefix(2),
                       [.catchGlide, .scrollBegan])
    }

    func testLosingTheHandEndsTheScrollWithoutAGlide() {
        let rig = Rig()
        rig.hold(0.5)
        rig.fist(true)
        rig.hold(0.15)
        let start = rig.pose.palm
        rig.run(0.2) { p, pose in pose.palm = start + Vec2(-0.6 * hu * p, 0) }
        rig.run(0.4, visible: false)
        XCTAssertEqual(rig.scrollEnds, [.zero])
        XCTAssertFalse(rig.engine.snapshot.isScrolling)
    }
}

final class FistAndPinchTests: XCTestCase {
    func testAPinchNeverTurnsIntoAScroll() {
        let rig = Rig()
        rig.hold(0.5)
        rig.pinch(true)
        rig.move(by: Vec2(0.3 * hu, 0), over: 0.3)
        rig.pose.fingersOpen = false
        rig.move(by: Vec2(0.3 * hu, 0), over: 0.6)
        XCTAssertEqual(rig.count(.scrollBegan), 0, "the thumb stays on the index tip")
        XCTAssertTrue(rig.scrolls.isEmpty)
        XCTAssertTrue(rig.clicks.isEmpty)
    }

    func testAScrollNeverTurnsIntoAPinch() {
        let rig = Rig()
        rig.hold(0.5)
        rig.fist(true)
        rig.hold(0.15)
        rig.move(by: Vec2(0, 0.3 * hu), over: 0.3)
        XCTAssertTrue(rig.engine.snapshot.isScrolling)
        rig.pose.fingersOpen = true
        rig.pose.thumbTucked = false
        rig.pose.pinchRatio = Rig.touching
        rig.move(by: Vec2(0.4 * hu, 0), over: 0.4)
        rig.pinch(false)
        rig.hold(0.3)
        XCTAssertEqual(rig.count(.scrollBegan), 1)
        XCTAssertEqual(rig.scrollEnds.count, 1)
        XCTAssertEqual(rig.count(.touchBegan), 0, "the tips must be seen apart after the fist")
        XCTAssertEqual(rig.pointerTravel().path, 0)
        XCTAssertTrue(rig.clicks.isEmpty)
    }

    func testScrollSnapshot() {
        let rig = Rig()
        rig.hold(0.5)
        rig.fist(true)
        rig.hold(0.15)
        XCTAssertTrue(rig.engine.snapshot.isScrolling)
        XCTAssertTrue(rig.engine.snapshot.isFist)
        XCTAssertFalse(rig.engine.snapshot.isTouching)
        XCTAssertTrue(rig.engine.isEngaged)
        rig.fist(false)
        rig.hold(0.1)
        XCTAssertFalse(rig.engine.snapshot.isScrolling)
        XCTAssertFalse(rig.engine.isEngaged)
    }

    /// Thumb, index and middle tips together was the three-finger scroll. It
    /// is gone: that pose neither scrolls nor points.
    func testThreeFingerTouchDoesNothing() {
        for seed in UInt64(1)...3 {
            let rig = Rig.webcam(seed: seed, fps: 30)
            rig.hold(0.6)
            rig.run(0.1) { p, pose in
                pose.pinchRatio = 0.8 + (Rig.touching - 0.8) * p
                pose.middleTouch = 0.3 + (Rig.touching - 0.3) * p
            }
            rig.move(by: Vec2(0, 1.0 * rig.pose.size), over: 0.5)
            rig.pose.middleTouch = nil
            rig.pinch(false, over: 0.08)
            rig.hold(0.3)
            XCTAssertEqual(rig.count(.scrollBegan), 0, "seed \(seed)")
            XCTAssertEqual(rig.count(.touchBegan), 0, "seed \(seed)")
            XCTAssertEqual(rig.pointerTravel().path, 0, "seed \(seed)")
            XCTAssertTrue(rig.clicks.isEmpty, "seed \(seed)")
        }
    }
}
