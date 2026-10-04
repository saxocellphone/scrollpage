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
    private let source: CGEventSource?
    private var timer: DispatchSourceTimer?
    private var lastTick = 0.0

    private var postingAllowed = false
    private var current = CGPoint.zero
    private var target = CGPoint.zero
    private var displays: [CGRect] = []
    private var buttonDown = false

    private var momentum = MomentumScroller()
    private var momentumPosted = false
    private var scrollRemainder = Vec2.zero

    /// Time constant for easing the pointer to its target.
    private let pointerTau = 0.022
    private let tickInterval = 1.0 / 120

    init() {
        source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
    }

    func setPostingAllowed(_ allowed: Bool) {
        queue.async {
            if !allowed { self.cancelEverything() }
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
        guard postingAllowed else { return }
        switch output {
        case .touchBegan:
            stopMomentum()
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

    private enum ScrollPhase: Int64 { case began = 1, changed = 2, ended = 4 }
    private enum MomentumPhase: Int64 { case none = 0, begin = 1, `continue` = 2, end = 3 }

    /// A fling is posted the way a trackpad reports one: a short gesture
    /// (began, ended) followed by momentum events the app can interrupt.
    private func fling(_ velocity: Vec2) {
        if momentumPosted {
            postScroll(.zero, phase: nil, momentum: .end)
            momentumPosted = false
        }
        momentum.fling(velocity)
        scrollRemainder = .zero
        postScroll(integerScroll(momentum.step(tickInterval)), phase: .began, momentum: .none)
        postScroll(.zero, phase: .ended, momentum: .none)
        ensureTimer()
    }

    private func stopMomentum() {
        if momentumPosted { postScroll(.zero, phase: nil, momentum: .end) }
        momentumPosted = false
        momentum.stop()
        scrollRemainder = .zero
    }

    private func integerScroll(_ d: Vec2) -> (x: Int32, y: Int32) {
        let total = d + scrollRemainder
        let x = total.x.rounded(.towardZero), y = total.y.rounded(.towardZero)
        scrollRemainder = Vec2(total.x - x, total.y - y)
        return (Int32(clamping: Int(x)), Int32(clamping: Int(y)))
    }

    private func postScroll(_ d: (x: Int32, y: Int32), phase: ScrollPhase?, momentum: MomentumPhase) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: d.y, wheel2: d.x, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase?.rawValue ?? 0)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.rawValue)
        e.post(tap: .cghidEventTap)
    }

    private func postScroll(_ d: Vec2, phase: ScrollPhase?, momentum: MomentumPhase) {
        postScroll((Int32(d.x), Int32(d.y)), phase: phase, momentum: momentum)
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

        if momentum.isActive {
            let d = integerScroll(momentum.step(dt))
            if !momentumPosted {
                postScroll(d, phase: nil, momentum: .begin)
                momentumPosted = true
            } else if d.x != 0 || d.y != 0 {
                postScroll(d, phase: nil, momentum: .continue)
            }
            if !momentum.isActive {
                postScroll(.zero, phase: nil, momentum: .end)
                momentumPosted = false
            }
        }

        if current == target && !momentum.isActive {
            timer?.cancel()
            timer = nil
        }
    }
}
