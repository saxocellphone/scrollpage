import XCTest
@testable import ScrollpageCore

final class OneEuroFilterTests: XCTestCase {
    func testReducesJitterOfStillSignal() {
        var noise = NoiseSource(seed: 7)
        var filter = OneEuroFilter2D()
        var rawSteps: [Double] = []
        var filteredSteps: [Double] = []
        var lastRaw = Vec2.zero, lastFiltered = Vec2.zero
        for i in 0..<600 {
            let raw = Vec2(noise.gaussian(0.005), noise.gaussian(0.005))
            let f = filter.filter(raw, at: Double(i) / 60)
            if i > 60 {
                rawSteps.append(raw.distance(to: lastRaw))
                filteredSteps.append(f.distance(to: lastFiltered))
            }
            lastRaw = raw
            lastFiltered = f
        }
        let rawMean = rawSteps.reduce(0, +) / Double(rawSteps.count)
        let filteredMean = filteredSteps.reduce(0, +) / Double(filteredSteps.count)
        XCTAssertLessThan(filteredMean, rawMean * 0.15)
    }

    func testTracksRampWithSmallLag() {
        var filter = OneEuroFilter2D()
        var output = Vec2.zero
        let speed = 3.0
        for i in 0...60 {
            let t = Double(i) / 60
            output = filter.filter(Vec2(speed * t, 0), at: t)
        }
        let lag = speed * 1.0 - output.x
        XCTAssertGreaterThan(lag, 0)
        XCTAssertLessThan(lag / speed, 0.05, "lag should stay under 50 ms at speed")
    }
}

final class PointerAccelerationTests: XCTestCase {
    let curve = PointerAcceleration(trackingSpeed: 0.5, screenWidth: 1512)

    func testGainAndOutputSpeedAreMonotonic() {
        var lastGain = 0.0, lastOutput = 0.0
        var v = 0.07
        while v < 20 {
            let g = curve.gain(forSpeed: v)
            XCTAssertGreaterThanOrEqual(g, lastGain - 1e-9)
            XCTAssertGreaterThanOrEqual(g * v, lastOutput - 1e-9)
            lastGain = g
            lastOutput = g * v
            v *= 1.05
        }
    }

    func testSlowIsPreciseAndFastCoversTheScreen() {
        XCTAssertEqual(curve.gain(forSpeed: 0.3), curve.slowGain, accuracy: 1e-9)
        XCTAssertEqual(curve.gain(forSpeed: 8), curve.fastGain, accuracy: 1e-9)
        XCTAssertGreaterThan(curve.fastGain / curve.slowGain, 6)
        XCTAssertGreaterThanOrEqual(curve.fastGain, 1512)
    }

    func testBelowRestSpeedNothingMoves() {
        XCTAssertEqual(curve.gain(forSpeed: 0), 0)
        XCTAssertEqual(curve.gain(forSpeed: 0.05), 0)
        XCTAssertLessThan(curve.gain(forSpeed: 0.08), curve.slowGain * 0.2)
    }

    func testTrackingSpeedScalesFastMoreThanSlow() {
        let slow = PointerAcceleration(trackingSpeed: 0, screenWidth: 1512)
        let fast = PointerAcceleration(trackingSpeed: 1, screenWidth: 1512)
        XCTAssertGreaterThan(fast.fastGain / slow.fastGain, fast.slowGain / slow.slowGain - 1e-9)
        XCTAssertGreaterThan(fast.slowGain, slow.slowGain)
    }
}

final class MomentumScrollerTests: XCTestCase {
    func testGlideDistanceIsVelocityTimesTau() {
        var m = MomentumScroller()
        m.fling(Vec2(0, 2000))
        var total = Vec2.zero
        var ticks = 0
        while m.isActive && ticks < 10_000 {
            total += m.step(1.0 / 120)
            ticks += 1
        }
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(total.y, 2000 * 0.325, accuracy: 2000 * 0.325 * 0.03)
        XCTAssertEqual(total.x, 0)
        XCTAssertLessThan(Double(ticks) / 120, 2.0, "glide stops in well under 2 s")
    }

    func testTickRateDoesNotChangeDistance() {
        func glide(_ hz: Double) -> Double {
            var m = MomentumScroller()
            m.fling(Vec2(1500, 0))
            var x = 0.0
            while m.isActive { x += m.step(1 / hz).x }
            return x
        }
        XCTAssertEqual(glide(60), glide(240), accuracy: 3)
    }

    func testSameDirectionFlingsChainAndOppositeReplaces() {
        var m = MomentumScroller()
        m.fling(Vec2(0, 1000))
        _ = m.step(0.05)
        let before = m.velocity.y
        m.fling(Vec2(0, 1000))
        XCTAssertEqual(m.velocity.y, before + 1000, accuracy: 1e-6)
        m.fling(Vec2(0, -800))
        XCTAssertEqual(m.velocity.y, -800, accuracy: 1e-6)
        m.fling(Vec2(0, -1e6))
        XCTAssertEqual(m.velocity.length, m.maxSpeed, accuracy: 1e-6)
        m.stop()
        XCTAssertFalse(m.isActive)
    }
}

final class HandSampleTests: XCTestCase {
    func testOpenHandVersusPinch() {
        var gen = SyntheticHand(seed: 1)
        let open = gen.sample(HandPose(pinchRatio: 0.9, fingersOpen: true))
        XCTAssertTrue(open.isOpenHand)
        XCTAssertEqual(open.extendedFingerCount, 4)
        XCTAssertGreaterThan(open.pinchRatio()!, 0.6)

        let pinch = gen.sample(HandPose(pinchRatio: 0.1, fingersOpen: false))
        XCTAssertFalse(pinch.isOpenHand)
        XCTAssertLessThan(pinch.pinchRatio()!, 0.2)

        let fist = gen.sample(HandPose(pinchRatio: 0.8, fingersOpen: false))
        XCTAssertFalse(fist.isOpenHand)
        XCTAssertEqual(fist.handSize!, 0.18, accuracy: 0.01)
    }
}
