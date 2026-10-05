import CoreGraphics
import Foundation
import QuartzCore
import ScrollpageCore

/// Posts mouse and scroll events system-wide.
///
/// Camera frames arrive at 30–60 Hz with jitter, so motion is never posted
/// directly from them. Gesture deltas move a target; a ~120 Hz timer eases the
/// pointer toward it and integrates the momentum glide, like a trackpad driver.
final class InputDriver {
    private let queue = DispatchQueue(label: "com.saxocellphone.scrollpage.input", qos: .userInteractive)
    private var source: CGEventSource?
    private var timer: DispatchSourceTimer?
    private var lastTick = 0.0

    private var postingAllowed = false
    private var current = CGPoint.zero
    private var target = CGPoint.zero
    private var displays: [CGRect] = []
    private var buttonDown = false

    private var scroller = FlingSequencer()
    private var systemNaturalScrolling = true

    /// Time constant for easing the pointer to its target.
    private let pointerTau = 0.022
    private let tickInterval = 1.0 / 120

    struct ScrollStats {
        var events = 0
        var momentumEvents = 0
        var wheel1: Int64 = 0
        var wheel2: Int64 = 0
        var momentumEnded = false
    }

    private var stats = ScrollStats()
    /// Counters for the last fling, for diagnostics.
    var scrollStats: ScrollStats { queue.sync { stats } }

    init() {
        source = Self.makeSource()
    }

    private static func makeSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        return source
    }

    func setPostingAllowed(_ allowed: Bool) {
        queue.async {
            if !allowed { self.cancelEverything() }
            // A source made before Accessibility was granted can stay unprivileged.
            if allowed && !self.postingAllowed { self.source = Self.makeSource() }
            if allowed != self.postingAllowed { Log.input.notice("posting allowed: \(allowed)") }
            self.postingAllowed = allowed
        }
    }

    func handle(_ outputs: [GestureOutput]) {
        guard !outputs.isEmpty else { return }
        queue.async {
            for output in outputs { self.apply(output) }
        }
    }

    // MARK: - Gesture outputs

    private func apply(_ output: GestureOutput) {
        guard postingAllowed else {
            if case .fling = output { Log.input.notice("fling dropped: posting not allowed (Accessibility not trusted or paused)") }
            return
        }
        switch output {
        case .catchGlide:
            if scroller.isActive { Log.input.notice("glide caught by touch after \(self.stats.events) scroll events") }
            stopMomentum()
        case .touchBegan:
            syncToRealCursor()
        case let .pointerMoved(dx, dy):
            target = clampToDisplays(CGPoint(x: target.x + dx, y: target.y + dy))
            ensureTimer()
        case let .click(count):
            settlePointer()
            postMouse(.leftMouseDown, clickState: count)
            queue.asyncAfter(deadline: .now() + 0.015) {
                self.postMouse(.leftMouseUp, clickState: count)
            }
        case .pressBegan:
            settlePointer()
            buttonDown = true
            postMouse(.leftMouseDown, clickState: 1)
        case .touchEnded:
            releaseButton()
        case let .fling(vx, vy):
            fling(Vec2(vx, vy))
        }
    }

    private func cancelEverything() {
        releaseButton()
        stopMomentum()
        target = current
    }

    private func releaseButton() {
        guard buttonDown else { return }
        settlePointer()
        postMouse(.leftMouseUp, clickState: 1)
        buttonDown = false
    }

    // MARK: - Pointer

    private func syncToRealCursor() {
        displays = Self.activeDisplayBounds()
        guard let real = CGEvent(source: nil)?.location else { return }
        let dx = real.x - current.x, dy = real.y - current.y
        if dx * dx + dy * dy > 1 {
            current = real
            target = real
        }
    }

    /// Jumps the eased pointer to its target so a click lands where it is aimed.
    private func settlePointer() {
        if current != target {
            let dx = target.x - current.x, dy = target.y - current.y
            current = target
            postMove(dx: dx, dy: dy)
        }
    }

    private func clampToDisplays(_ p: CGPoint) -> CGPoint {
        if displays.isEmpty { displays = Self.activeDisplayBounds() }
        if displays.contains(where: { $0.contains(p) }) { return p }
        guard let home = displays.first(where: { $0.contains(current) }) ?? displays.first else { return p }
        return CGPoint(x: min(max(p.x, home.minX), home.maxX - 1),
                       y: min(max(p.y, home.minY), home.maxY - 1))
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    private func postMove(dx: Double, dy: Double) {
        let type: CGEventType = buttonDown ? .leftMouseDragged : .mouseMoved
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: current, mouseButton: .left) else { return }
        e.setDoubleValueField(.mouseEventDeltaX, value: dx)
        e.setDoubleValueField(.mouseEventDeltaY, value: dy)
        e.post(tap: .cghidEventTap)
    }

    private func postMouse(_ type: CGEventType, clickState: Int) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: current, mouseButton: .left) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Scrolling

    /// A fling is posted the way a trackpad reports one: a short gesture
    /// (began, changed…, ended) followed by momentum events the app can interrupt.
    private func fling(_ velocity: Vec2) {
        systemNaturalScrolling = Permissions.systemNaturalScrolling
        Log.input.notice("fling vx=\(velocity.x, format: .fixed(precision: 0)) vy=\(velocity.y, format: .fixed(precision: 0)) systemNatural=\(self.systemNaturalScrolling)")
        let events = scroller.fling(velocity, dt: tickInterval)
        post(events.filter { $0.momentum == .end })
        stats = ScrollStats()
        post(events.filter { $0.momentum != .end })
        ensureTimer()
    }

    private func stopMomentum() {
        post(scroller.stop())
    }

    private func post(_ events: [ScrollEvent]) {
        for event in events { postScroll(event) }
    }

    private func postScroll(_ s: ScrollEvent) {
        let w = s.wheels(systemNaturalScrolling: systemNaturalScrolling)
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: w.wheel1, wheel2: w.wheel2, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: s.phase.rawValue)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: s.momentum.rawValue)
        e.post(tap: .cghidEventTap)
        stats.events += 1
        if s.momentum != .none { stats.momentumEvents += 1 }
        stats.wheel1 += Int64(w.wheel1)
        stats.wheel2 += Int64(w.wheel2)
        if s.momentum == .end {
            stats.momentumEnded = true
            Log.input.notice("glide ended: \(self.stats.events) scroll events, wheel1 \(self.stats.wheel1) px, wheel2 \(self.stats.wheel2) px")
        }
    }

    // MARK: - Timer

    private func ensureTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: tickInterval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        lastTick = CACurrentMediaTime()
        timer = t
        t.resume()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.05, max(0.001, now - lastTick))
        lastTick = now

        let dx = target.x - current.x, dy = target.y - current.y
        if dx * dx + dy * dy > 0.0025 {
            let a = 1 - exp(-dt / pointerTau)
            var step = CGPoint(x: dx * a, y: dy * a)
            if (dx - step.x) * (dx - step.x) + (dy - step.y) * (dy - step.y) < 0.0025 { step = CGPoint(x: dx, y: dy) }
            current = CGPoint(x: current.x + step.x, y: current.y + step.y)
            postMove(dx: step.x, dy: step.y)
        } else if current != target {
            current = target
        }

        if scroller.isActive { post(scroller.tick(dt)) }

        if current == target && !scroller.isActive {
            timer?.cancel()
            timer = nil
        }
    }
}
