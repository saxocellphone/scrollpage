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

    /// A fist scroll: camera frames add distance every 1/30 s while the
    /// sequencer ticks at 120 Hz, then the fist opens with a release velocity.
    private func dragThenRelease(_ frames: Int, perFrame: Vec2, velocity: Vec2) -> (drag: [ScrollEvent], after: [ScrollEvent]) {
        var s = FlingSequencer()
        var drag = s.beginDrag()
        for _ in 0..<frames {
            s.drag(perFrame)
            for _ in 0..<4 { drag += s.tick(dt) }
        }
        var after = s.endDrag(velocity: velocity)
        var ticks = 0
        while s.isActive && ticks < 2000 { after += s.tick(dt); ticks += 1 }
        return (drag, after)
    }

    func testDragIsAGestureThenMomentum() {
        let (drag, after) = dragThenRelease(10, perFrame: Vec2(0, -12), velocity: Vec2(0, -900))
        XCTAssertEqual(drag.first?.phase, .began)
        XCTAssertTrue(drag.dropFirst().allSatisfy { $0.phase == .changed })
        XCTAssertGreaterThan(drag.count, 10, "eased over the ticks between camera frames")
        XCTAssertTrue(drag.allSatisfy { $0.momentum == .none })

        let ended = after.firstIndex { $0.phase == .ended }!
        XCTAssertTrue(after[..<ended].allSatisfy { $0.phase == .changed })
        let momentum = after[(ended + 1)...].map(\.momentum)
        XCTAssertEqual(momentum.first, .begin)
        XCTAssertEqual(momentum.last, .end)
        XCTAssertTrue(momentum.dropFirst().dropLast().allSatisfy { $0 == .continue })

        let dragged = (drag + after[..<ended]).reduce(0) { $0 + Int($1.dy) }
        XCTAssertEqual(dragged, -120, "pixel-precise: every point of hand motion is posted")
        let glide = after[(ended + 1)...].reduce(0) { $0 + Int($1.dy) }
        XCTAssertEqual(Double(glide), -900 * MomentumScroller().timeConstant, accuracy: 15)
    }

    func testDragWithoutVelocityEndsWithoutMomentum() {
        let (drag, after) = dragThenRelease(6, perFrame: Vec2(7, 0), velocity: .zero)
        XCTAssertEqual(drag.reduce(0) { $0 + Int($1.dx) } + after.reduce(0) { $0 + Int($1.dx) }, 42)
        XCTAssertEqual(after.last, ScrollEvent(phase: .ended))
        XCTAssertTrue(after.allSatisfy { $0.momentum == .none })
    }

    func testDragThatNeverMovedPostsNothing() {
        let (drag, after) = dragThenRelease(5, perFrame: .zero, velocity: Vec2(0, 900))
        XCTAssertEqual(drag, [])
        XCTAssertEqual(after, [])
    }

    func testBeginDragStopsAGlide() {
        var s = FlingSequencer()
        _ = s.fling(Vec2(0, 2000), dt: dt)
        for _ in 0..<(FlingSequencer.gestureTicks + 5) { _ = s.tick(dt) }
        XCTAssertEqual(s.beginDrag(), [ScrollEvent(momentum: .end)])
        XCTAssertTrue(s.isDragging)
        XCTAssertEqual(s.momentum.isActive, false)
    }

    func testStopDuringADragEndsIt() {
        var s = FlingSequencer()
        _ = s.beginDrag()
        s.drag(Vec2(0, 30))
        _ = s.tick(dt)
        XCTAssertEqual(s.stop(), [ScrollEvent(phase: .ended)])
        XCTAssertFalse(s.isActive)
    }

    /// Measured: with natural scrolling on, the window server flips posted
    /// vertical deltas but not horizontal ones.
    func testWheelSigns() {
        let e = ScrollEvent(dx: 5, dy: 7)
        XCTAssertTrue(e.wheels(systemNaturalScrolling: true) == (-7, 5))
        XCTAssertTrue(e.wheels(systemNaturalScrolling: false) == (7, 5))
    }
}
