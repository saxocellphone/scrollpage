import Foundation

/// `CGScrollPhase` raw values.
public enum ScrollPhase: Int64, Sendable { case none = 0, began = 1, changed = 2, ended = 4 }
/// `CGMomentumScrollPhase` raw values.
public enum MomentumPhase: Int64, Sendable { case none = 0, begin = 1, `continue` = 2, end = 3 }

/// One continuous scroll-wheel event, in whole content points (y-down: positive
/// `dy` moves the content down, positive `dx` moves it right).
public struct ScrollEvent: Equatable, Sendable {
    public var dx: Int32
    public var dy: Int32
    public var phase: ScrollPhase
    public var momentum: MomentumPhase

    public init(dx: Int32 = 0, dy: Int32 = 0, phase: ScrollPhase = .none, momentum: MomentumPhase = .none) {
        self.dx = dx
        self.dy = dy
        self.phase = phase
        self.momentum = momentum
    }

    /// `CGEvent` wheel values for this event. When the system's natural
    /// scrolling is on, the window server flips the vertical delta of a posted
    /// continuous scroll event but not the horizontal one (measured on macOS 26),
    /// so only `wheel1` is pre-inverted.
    public func wheels(systemNaturalScrolling: Bool) -> (wheel1: Int32, wheel2: Int32) {
        (systemNaturalScrolling ? -dy : dy, dx)
    }
}

/// Turns flings and drags into the event stream of a trackpad scroll.
///
/// A fling is a flick: a short finger-down gesture (began, changed…, ended) and
/// then a momentum glide (begin, continue…, end). AppKit drops a gesture whose
/// began is followed straight by ended, and the momentum after it, so nothing
/// scrolls. It needs changed events on separate frames, so the gesture lasts
/// `gestureTicks` ticks before the glide takes over.
///
/// A drag is two fingers moving on the pad: began with the first motion,
/// changed while it moves, ended when the fingers lift, then the glide. Drag
/// distance arrives with each camera frame and is eased out over the ticks
/// (time constant `dragTau`), so the content moves smoothly between frames.
public struct FlingSequencer: Sendable {
    public static let gestureTicks = 3
    public static let dragTau = 0.03

    public private(set) var momentum: MomentumScroller
    private var remainder = Vec2.zero
    private var gestureTicksLeft = 0
    private var momentumPosted = false
    public private(set) var isDragging = false
    private var dragBegan = false
    /// Drag distance not posted yet.
    private var pending = Vec2.zero

    public init(momentum: MomentumScroller = MomentumScroller()) {
        self.momentum = momentum
    }

    /// True while there is anything left to post.
    public var isActive: Bool { isDragging || gestureTicksLeft > 0 || momentumPosted || momentum.isActive }

    /// Fingers down for a drag: ends any fling or glide still under way.
    public mutating func beginDrag() -> [ScrollEvent] {
        let out = stop()
        isDragging = true
        return out
    }

    /// Adds content distance (points, y-down) to the drag.
    public mutating func drag(_ d: Vec2) {
        guard isDragging else { return }
        pending += d
    }

    /// Fingers up: posts the rest of the drag, ends the gesture, and glides at
    /// `velocity` (points per second) if the drag had begun.
    public mutating func endDrag(velocity: Vec2) -> [ScrollEvent] {
        guard isDragging else { return [] }
        var out: [ScrollEvent] = []
        if dragBegan {
            let e = event(pending, phase: .changed)
            if e.dx != 0 || e.dy != 0 { out.append(e) }
            out.append(ScrollEvent(phase: .ended))
            if velocity.length > 0 { momentum.fling(velocity) }
        }
        isDragging = false
        dragBegan = false
        pending = .zero
        remainder = .zero
        return out
    }

    /// Starts (or extends) a fling. `dt` is the tick interval, for the began delta.
    public mutating func fling(_ velocity: Vec2, dt: Double) -> [ScrollEvent] {
        var out = endDrag(velocity: .zero)
        if momentumPosted {
            out.append(ScrollEvent(momentum: .end))
            momentumPosted = false
        }
        momentum.fling(velocity)
        remainder = .zero
        if gestureTicksLeft == 0 {
            out.append(event(momentum.step(dt), phase: .began))
        }
        gestureTicksLeft = Self.gestureTicks
        return out
    }

    /// Stops any glide, ending whatever phase is open.
    public mutating func stop() -> [ScrollEvent] {
        var out: [ScrollEvent] = []
        if gestureTicksLeft > 0 || dragBegan { out.append(ScrollEvent(phase: .ended)) }
        if momentumPosted { out.append(ScrollEvent(momentum: .end)) }
        gestureTicksLeft = 0
        momentumPosted = false
        isDragging = false
        dragBegan = false
        pending = .zero
        momentum.stop()
        remainder = .zero
        return out
    }

    public mutating func tick(_ dt: Double) -> [ScrollEvent] {
        var out: [ScrollEvent] = []
        if isDragging {
            guard pending != .zero else { return out }
            var step = pending * (1 - exp(-max(0, dt) / Self.dragTau))
            if (pending - step).length < 0.5 { step = pending }
            pending = pending - step
            let e = event(step, phase: dragBegan ? .changed : .began)
            if e.dx != 0 || e.dy != 0 {
                out.append(e)
                dragBegan = true
            }
            return out
        }
        if gestureTicksLeft > 0 {
            out.append(event(momentum.step(dt), phase: .changed))
            gestureTicksLeft -= 1
            if gestureTicksLeft == 0 { out.append(ScrollEvent(phase: .ended)) }
            return out
        }
        guard momentum.isActive else { return out }
        let e = event(momentum.step(dt), momentum: momentumPosted ? .continue : .begin)
        if !momentumPosted || e.dx != 0 || e.dy != 0 { out.append(e) }
        momentumPosted = true
        if !momentum.isActive {
            out.append(ScrollEvent(momentum: .end))
            momentumPosted = false
        }
        return out
    }

    private mutating func event(_ d: Vec2, phase: ScrollPhase = .none, momentum: MomentumPhase = .none) -> ScrollEvent {
        let total = d + remainder
        let x = total.x.rounded(.towardZero), y = total.y.rounded(.towardZero)
        remainder = Vec2(total.x - x, total.y - y)
        return ScrollEvent(dx: Int32(clamping: Int(x)), dy: Int32(clamping: Int(y)), phase: phase, momentum: momentum)
    }
}
