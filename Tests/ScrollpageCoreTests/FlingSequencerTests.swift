import XCTest
@testable import ScrollpageCore

final class FlingSequencerTests: XCTestCase {
    private let dt = 1.0 / 120

    /// Every tick's events, starting with the fling's own.
    private func run(_ velocity: Vec2) -> [[ScrollEvent]] {
        var s = FlingSequencer()
        var ticks = [s.fling(velocity, dt: dt)]
        while s.isActive && ticks.count < 2000 { ticks.append(s.tick(dt)) }
        return ticks
    }

    /// AppKit ignores began followed straight by ended (and the momentum after
    /// it): the gesture needs changed events on separate frames.
    func testFlingIsAGestureWithChangedEventsThenMomentum() {
        let ticks = run(Vec2(0, -2000))
        let events = ticks.flatMap { $0 }
        XCTAssertEqual(events.first?.phase, .began)

        let changedTicks = ticks.filter { $0.contains { $0.phase == .changed } }
        XCTAssertGreaterThanOrEqual(changedTicks.count, 2)
        XCTAssertTrue(changedTicks.allSatisfy { $0.filter { $0.phase == .changed }.count == 1 })
        XCTAssertFalse(ticks[0].contains { $0.phase == .ended }, "ended must not share the began frame")

        let endedIndex = events.firstIndex { $0.phase == .ended }!
        let firstMomentum = events.firstIndex { $0.momentum != .none }!
        XCTAssertLessThan(endedIndex, firstMomentum)
        XCTAssertTrue(events[..<endedIndex].dropFirst().allSatisfy { $0.phase == .changed })
        XCTAssertTrue(events.allSatisfy { $0.phase == .none || $0.momentum == .none })

        let momentum = events[firstMomentum...].map(\.momentum)
        XCTAssertEqual(momentum.first, .begin)
        XCTAssertEqual(momentum.last, .end)
        XCTAssertTrue(momentum.dropFirst().dropLast().allSatisfy { $0 == .continue })
        XCTAssertGreaterThan(momentum.count, 20)
    }

    func testTotalDistanceIsTheGlide() {
        let events = run(Vec2(0, -2000)).flatMap { $0 }
        let total = events.reduce(0) { $0 + Int($1.dy) }
        XCTAssertEqual(Double(total), -2000 * MomentumScroller().timeConstant, accuracy: 15)
        XCTAssertTrue(events.allSatisfy { $0.dx == 0 && $0.dy <= 0 })
    }

    func testStopEndsWhicheverPhaseIsOpen() {
        var s = FlingSequencer()
        _ = s.fling(Vec2(0, 2000), dt: dt)
        _ = s.tick(dt)
        XCTAssertEqual(s.stop(), [ScrollEvent(phase: .ended)])
        XCTAssertFalse(s.isActive)

        _ = s.fling(Vec2(0, 2000), dt: dt)
        for _ in 0..<(FlingSequencer.gestureTicks + 2) { _ = s.tick(dt) }
        XCTAssertEqual(s.stop(), [ScrollEvent(momentum: .end)])
        XCTAssertFalse(s.isActive)
        XCTAssertEqual(s.stop(), [])
    }

    func testFlingDuringGlideEndsMomentumAndStartsANewGesture() {
        var s = FlingSequencer()
        _ = s.fling(Vec2(0, 2000), dt: dt)
        for _ in 0..<10 { _ = s.tick(dt) }
        let events = s.fling(Vec2(0, 2000), dt: dt)
        XCTAssertEqual(events.map(\.momentum), [.end, .none])
        XCTAssertEqual(events.last?.phase, .began)
    }

    /// Measured: with natural scrolling on, the window server flips posted
    /// vertical deltas but not horizontal ones.
    func testWheelSigns() {
        let e = ScrollEvent(dx: 5, dy: 7)
        XCTAssertTrue(e.wheels(systemNaturalScrolling: true) == (-7, 5))
        XCTAssertTrue(e.wheels(systemNaturalScrolling: false) == (7, 5))
    }
}
