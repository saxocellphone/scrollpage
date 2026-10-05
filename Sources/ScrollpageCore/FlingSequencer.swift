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

/// Turns flings into the event stream of a trackpad flick: a short finger-down
/// gesture (began, changed…, ended) and then a momentum glide (begin,
/// continue…, end).
///
/// AppKit drops a gesture whose began is followed straight by ended, and the
/// momentum after it, so nothing scrolls. It needs changed events on separate
/// frames, so the gesture lasts `gestureTicks` ticks before the glide takes over.
public struct FlingSequencer: Sendable {
    public static let gestureTicks = 3

    public private(set) var momentum: MomentumScroller
    private var remainder = Vec2.zero
    private var gestureTicksLeft = 0
    private var momentumPosted = false

    public init(momentum: MomentumScroller = MomentumScroller()) {
        self.momentum = momentum
    }

    /// True while there is anything left to post.
    public var isActive: Bool { gestureTicksLeft > 0 || momentumPosted || momentum.isActive }

    /// Starts (or extends) a fling. `dt` is the tick interval, for the began delta.
    public mutating func fling(_ velocity: Vec2, dt: Double) -> [ScrollEvent] {
        var out: [ScrollEvent] = []
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
        if gestureTicksLeft > 0 { out.append(ScrollEvent(phase: .ended)) }
        if momentumPosted { out.append(ScrollEvent(momentum: .end)) }
        gestureTicksLeft = 0
        momentumPosted = false
        momentum.stop()
        remainder = .zero
        return out
    }

    public mutating func tick(_ dt: Double) -> [ScrollEvent] {
        var out: [ScrollEvent] = []
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
