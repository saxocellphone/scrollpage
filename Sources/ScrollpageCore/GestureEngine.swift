import Foundation

public enum GestureOutput: Equatable, Sendable {
    /// Pinch went down: the finger touched the pad.
    case touchBegan
    /// Stop the momentum glide. Sent just before a touch begins while a glide
    /// could still be running, unless the touch comes too soon after a fling to
    /// be a deliberate catch.
    case catchGlide
    /// Pointer displacement in screen points (y-down).
    case pointerMoved(dx: Double, dy: Double)
    /// Tap-to-click. `count` is 1, 2 or 3 (double and triple click).
    case click(count: Int)
    /// Pinch held still long enough: press the button so moving drags.
    case pressBegan
    /// Pinch released (or the hand was lost). Releases the button if pressed.
    case touchEnded
    /// Start a momentum glide. Content velocity in points per second, y-down:
    /// positive `vy` moves the content down, positive `vx` moves it right.
    case fling(vx: Double, vy: Double)
    /// Thumb, index and middle touched: two fingers are on the pad. Any glide
    /// stops, since a new scroll gesture replaces it.
    case scrollBegan
    /// Content displacement in points while the three fingers move, with the
    /// same signs as `fling`.
    case scrolled(dx: Double, dy: Double)
    /// The fingers lifted. Content velocity for the glide that follows, zero for
    /// none (a slow release, or a touch given up because the hand was lost).
    case scrollEnded(vx: Double, vy: Double)
}

public struct MotionSettings: Equatable, Sendable {
    public var trackingSpeed: Double
    public var scrollingSpeed: Double
    public var naturalScrolling: Bool
    public var screenWidth: Double

    public init(trackingSpeed: Double = 0.5, scrollingSpeed: Double = 0.5,
                naturalScrolling: Bool = true, screenWidth: Double = 1512) {
        self.trackingSpeed = trackingSpeed
        self.scrollingSpeed = scrollingSpeed
        self.naturalScrolling = naturalScrolling
        self.screenWidth = screenWidth
    }

    /// Content points per hand unit of three-finger motion: 250 to 1000, 500 at
    /// the middle of the Scrolling speed slider. A hand unit is about 10 cm, so
    /// the default moves a page about as far as the hand moves on screen.
    public var scrollGain: Double { 250 * pow(4, clamp01(scrollingSpeed)) }
}

/// What the UI needs to know about the current frame.
public struct GestureSnapshot: Equatable, Sendable {
    public var handVisible = false
    public var isOpenHand = false
    /// A pinch is down (the pointer finger).
    public var isTouching = false
    public var isPressed = false
    /// A three-finger scroll is under way.
    public var isScrolling = false
    public var pinchRatio: Double?
    public var touch = TouchMeasure()
    public var handSize: Double?
    /// Hand speed used for acceleration, in hand units per second.
    public var speed: Double = 0
    /// The pointer displacement this frame would produce if the hand were
    /// pinching. Used by diagnostics to measure drift of a still hand.
    public var potentialDelta = Vec2.zero
    /// Gestures drive the pointer. When false only the toggle is watched.
    public var controlOn = true
    /// Progress (0...1) of a raised-palm hold toward toggling control.
    public var toggleProgress = 0.0
    /// The raised-palm toggle fired on this frame; `controlOn` is the new state.
    public var toggled = false
    /// Why a fast motion this frame could not start a flick, if it couldn't.
    public var flickBlocked: String?

    public init() {}
}

public struct GestureTiming: Equatable, Sendable {
    /// Motion (hand units) a pinch may wander and still count as a tap.
    public var tapSlop = 0.09
    public var maxTapDuration = 0.35
    public var doubleClickInterval = 0.5
    /// Holding a pinch still this long presses the button (drag).
    public var pressDelay = 0.6
    /// Tracking gaps up to this long are bridged without ending a touch.
    public var lostGrace = 0.15
    /// After a pinch ends, no flick for this long.
    public var flickAfterRelease = 0.25
    /// A newly acquired hand must be tracked this long before it can flick.
    public var flickAfterAcquire = 0.15
    /// After a toggle, no flick until the hand has left the raised palm for this
    /// long and come to rest, so lowering the hand doesn't scroll.
    public var flickAfterToggle = 0.4
    /// A pinch this soon after a fling does not stop the glide: on a webcam the
    /// hand often closes into a pinch ~0.1 s after flicking, which would end the
    /// scroll almost as soon as it started.
    public var glideCatchDelay = 0.4
    /// Window over which hand speed is measured for acceleration.
    public var speedWindow = 0.08
    /// Three-finger release velocity is a recency-weighted fit over this window
    /// of the last frames in firm contact.
    public var scrollReleaseWindow = 0.1
    /// Releases slower than this (content points per second) don't glide.
    public var minScrollMomentum = 150.0
    public var maxScrollMomentum = 5000.0
    /// No glide if the fingers took longer than this to part after the last
    /// frame in firm contact: the velocity would be stale.
    public var scrollReleaseStale = 0.15

    public init() {}
}

/// Turns a stream of hand samples into trackpad-like events.
///
/// - Pinch and move is a finger on the pad: relative pointer motion, with
///   velocity-based acceleration.
/// - A quick pinch without moving is tap-to-click (double tap double-clicks).
/// - Pinch and hold still, then move, drags.
/// - Thumb, index and middle together, then move, is two-finger scrolling: the
///   content follows the hand, and glides on a quick release.
/// - A flick of the open hand starts a momentum scroll; a touch catches it.
/// - An open hand, or no hand, is a lifted finger: nothing moves.
/// - A raised palm, five fingers spread, held still for a second turns control
///   off or back on. While off, nothing but that toggle is recognized.
///
/// Only a touch confirmed by `TouchDetector` moves the pointer or scrolls.
///
/// Pure and deterministic: feed it samples with their capture timestamps.
public final class GestureEngine {
    public var settings: MotionSettings {
        didSet { acceleration = PointerAcceleration(trackingSpeed: settings.trackingSpeed, screenWidth: settings.screenWidth) }
    }
    public var timing: GestureTiming
    public private(set) var acceleration: PointerAcceleration
    public private(set) var snapshot = GestureSnapshot()
    public private(set) var controlOn = true

    public var touches = TouchDetector()
    public var filter = OneEuroFilter2D()
    public var flick = FlickDetector()
    public var toggle = ToggleGestureDetector()

    private struct Touch {
        var kind: TouchKind
        var start: Double
        var origin: Vec2
        var moved = false
        var pressed = false
    }

    private var touch: Touch?
    private var handSize: Double?
    private var previousPalm: Vec2?
    /// Integrated hand position in hand units. Only differences matter.
    private var virtual = Vec2.zero
    private var previousFiltered: Vec2?
    private var history: [(t: Double, p: Vec2)] = []
    private var trackedSince: Double?
    private var lastSeen: Double?
    private var lastRelease = -Double.infinity
    /// When the last glide started, and how soon after it a touch may catch it.
    private var glide: (start: Double, catchDelay: Double)?
    private var lastClick: (t: Double, count: Int)?
    private var movedSinceClick = false
    /// Content offset of the three-finger scroll on each frame in firm contact.
    private var scrollTrack: [(t: Double, offset: Vec2)] = []
    private var scrollOffset = Vec2.zero
    /// End of the post-toggle flick hold-off; infinite while the palm is still raised.
    private var flickHoldoff: Double?

    public init(settings: MotionSettings = MotionSettings(), timing: GestureTiming = GestureTiming()) {
        self.settings = settings
        self.timing = timing
        self.acceleration = PointerAcceleration(trackingSpeed: settings.trackingSpeed, screenWidth: settings.screenWidth)
    }

    /// A gesture is under way or starting (a touch, its confirmation, or a
    /// raised-palm hold), so the hand driving it must not be swapped.
    public var isEngaged: Bool { touch != nil || touches.isEngaged || toggle.isHolding }

    /// Ends any touch without clicking and forgets the hand.
    public func reset() -> [GestureOutput] {
        var out: [GestureOutput] = []
        loseHand(at: lastSeen ?? 0, &out)
        return out
    }

    /// Turns control on or off from outside (the menu). Turning it off ends any
    /// touch without clicking; with no touch down, it catches any glide like a
    /// finger landing on the pad and lifting.
    public func setControl(on: Bool) -> [GestureOutput] {
        var out: [GestureOutput] = []
        applyControl(on, at: lastSeen ?? 0, &out)
        snapshot.controlOn = controlOn
        snapshot.toggled = false
        return out
    }

    public func process(_ hand: HandSample?, at t: Double) -> [GestureOutput] {
        var out: [GestureOutput] = []
        guard let hand, let palm = hand.palmCenter, let rawSize = hand.handSize else {
            if let seen = lastSeen, t - seen > timing.lostGrace {
                loseHand(at: t, &out)
            }
            snapshot.handVisible = false
            snapshot.toggled = false
            snapshot.toggleProgress = toggle.progress
            snapshot.controlOn = controlOn
            return out
        }

        if trackedSince == nil {
            trackedSince = t
            flick.reset()
            flick.requireRest()
        }
        lastSeen = t

        let size = handSize.map { $0 + (rawSize - $0) * 0.2 } ?? rawSize
        handSize = size
        if let prev = previousPalm { virtual += (palm - prev) / size }
        previousPalm = palm

        let filtered = filter.filter(virtual, at: t)
        let delta = previousFiltered.map { filtered - $0 } ?? .zero
        previousFiltered = filtered
        let speed = measureSpeed(filtered, at: t)
        let pointerDelta = acceleration.displacement(for: delta, speed: speed)

        var blocked: String?
        let toggled = toggle.update(hand, handSize: size, position: filtered, speed: speed, at: t)
        if toggled {
            applyControl(!controlOn, at: t, &out)
            flickHoldoff = .infinity
        }
        if let until = flickHoldoff {
            if until == .infinity, !toggle.inPose {
                flickHoldoff = t + timing.flickAfterToggle
            } else if t >= until {
                flickHoldoff = nil
                flick.requireRest()
            }
        }

        if !controlOn || toggled {
            // Only the toggle is watched, and a touch must start from fingers apart.
            touches.reset()
        } else {
            switch touches.update(hand, handSize: size, at: t) {
            case .began(let kind):
                touch = Touch(kind: kind, start: t, origin: filtered)
                flick.reset()
                if let g = glide, t - g.start >= g.catchDelay, t - g.start <= MomentumScroller().maxGlideDuration {
                    out.append(.catchGlide)
                    glide = nil
                }
                if kind == .pinch {
                    out.append(.touchBegan)
                } else {
                    glide = nil
                    scrollOffset = .zero
                    scrollTrack = [(t, .zero)]
                    out.append(.scrollBegan)
                }
            case let .ended(_, lifted):
                endTouch(at: t, lifted: lifted, &out)
            case nil:
                if let current = touch {
                    continueTouch(current, filtered: filtered, delta: delta, speed: speed,
                                  pointerDelta: pointerDelta, at: t, &out)
                } else {
                    blocked = watchFlick(hand, speed: speed, at: t, &out)
                }
            }
        }

        snapshot = GestureSnapshot()
        snapshot.handVisible = true
        snapshot.isOpenHand = hand.isOpenHand
        snapshot.isTouching = touch?.kind == .pinch
        snapshot.isPressed = touch?.pressed ?? false
        snapshot.isScrolling = touch?.kind == .threeFinger
        snapshot.pinchRatio = touches.measure.thumbIndex
        snapshot.touch = touches.measure
        snapshot.handSize = size
        snapshot.speed = speed
        snapshot.potentialDelta = pointerDelta
        snapshot.controlOn = controlOn
        snapshot.toggleProgress = toggle.progress
        snapshot.toggled = toggled
        snapshot.flickBlocked = blocked
        return out
    }

    private func continueTouch(_ current: Touch, filtered: Vec2, delta: Vec2, speed: Double, pointerDelta: Vec2,
                               at t: Double, _ out: inout [GestureOutput]) {
        var current = current
        defer { touch = current }
        if current.kind == .threeFinger {
            guard touches.canMove else { return }
            let d = scrollDelta(for: delta, speed: speed)
            scrollOffset += d
            scrollTrack.append((t, scrollOffset))
            while let first = scrollTrack.first, t - first.t > 2 * timing.scrollReleaseWindow { scrollTrack.removeFirst() }
            if d != .zero { out.append(.scrolled(dx: d.x, dy: d.y)) }
            return
        }
        if !current.moved && filtered.distance(to: current.origin) > timing.tapSlop {
            current.moved = true
        }
        if !current.moved && !current.pressed && t - current.start >= timing.pressDelay {
            current.pressed = true
            out.append(.pressBegan)
        }
        if current.moved && touches.canMove && pointerDelta != .zero {
            movedSinceClick = true
            out.append(.pointerMoved(dx: pointerDelta.x, dy: pointerDelta.y))
        }
    }

    /// Content follows the hand one to one at `scrollGain`, fading out only
    /// below the pointer's rest speed so a still hand doesn't creep the page.
    private func scrollDelta(for handDelta: Vec2, speed: Double) -> Vec2 {
        let rest = speed > acceleration.restSpeed ? smoothstep(acceleration.restSpeed, acceleration.restBlendSpeed, speed) : 0
        let d = handDelta * (settings.scrollGain * rest)
        return settings.naturalScrolling ? d : -d
    }

    private func watchFlick(_ hand: HandSample, speed: Double, at t: Double, _ out: inout [GestureOutput]) -> String? {
        var blocked: String?
        let afterRelease = t - lastRelease >= timing.flickAfterRelease
        let afterAcquire = t - (trackedSince ?? t) >= timing.flickAfterAcquire
        let afterToggle = flickHoldoff == nil
        if !flick.inStroke && speed > flick.config.startSpeed {
            if !hand.isOpenHand {
                blocked = "hand not open (\(hand.extendedFingerCount) fingers)"
            } else if !afterRelease {
                blocked = "just released a touch"
            } else if !afterAcquire {
                blocked = "hand just appeared"
            } else if !afterToggle {
                blocked = "just toggled control"
            }
        }
        let mayFlick = afterRelease && afterAcquire && afterToggle && hand.isOpenHand
        if let f = flick.update(position: virtual, at: t, canStart: mayFlick) {
            glide = (t, timing.glideCatchDelay)
            out.append(fling(for: f))
        }
        return blocked
    }

    private func applyControl(_ on: Bool, at t: Double, _ out: inout [GestureOutput]) {
        guard on != controlOn else { return }
        controlOn = on
        if !on {
            if touch == nil {
                out += [.catchGlide, .touchBegan, .touchEnded]
            } else {
                endTouch(at: t, lifted: false, &out)
            }
            glide = nil
            lastClick = nil
        }
        touches.reset()
        flick.reset()
        flick.requireRest()
    }

    /// Speed over the last ~80 ms of filtered motion. A per-frame difference is
    /// too noisy to pick the acceleration gain from.
    private func measureSpeed(_ p: Vec2, at t: Double) -> Double {
        history.append((t, p))
        while history.count > 2, t - history[1].t >= timing.speedWindow { history.removeFirst() }
        guard let first = history.first, t > first.t else { return 0 }
        return p.distance(to: first.p) / (t - first.t)
    }

    private func fling(for f: Flick) -> GestureOutput {
        let gain = lerp(0.5, 2.0, clamp01(settings.scrollingSpeed))
        let magnitude = min(16_000, 1500 * pow(f.peakSpeed / FlickConfig().minPeakSpeed, 1.5) * gain)
        let direction = settings.naturalScrolling ? f.direction : -f.direction
        let v = direction * magnitude
        return .fling(vx: v.x, vy: v.y)
    }

    /// Velocity of the scroll at release: a least-squares slope over the last
    /// `scrollReleaseWindow` of firm contact, newer frames weighted up to twice
    /// as much, so the jitter of a single frame doesn't decide the glide.
    private func releaseVelocity(at t: Double) -> Vec2 {
        guard let last = scrollTrack.last, t - last.t <= timing.scrollReleaseStale else { return .zero }
        let window = scrollTrack.filter { last.t - $0.t <= timing.scrollReleaseWindow + 1e-9 }
        guard let first = window.first, last.t > first.t else { return .zero }
        let span = last.t - first.t
        let weights = window.map { 1 + ($0.t - first.t) / span }
        let total = weights.reduce(0, +)
        let tMean = zip(window, weights).reduce(0) { $0 + $1.0.t * $1.1 } / total
        let pMean = zip(window, weights).reduce(Vec2.zero) { $0 + $1.0.offset * $1.1 } / total
        var num = Vec2.zero, den = 0.0
        for (s, w) in zip(window, weights) {
            num += (s.offset - pMean) * (w * (s.t - tMean))
            den += w * (s.t - tMean) * (s.t - tMean)
        }
        guard den > 0 else { return .zero }
        var v = num / den
        let speed = v.length
        if speed < timing.minScrollMomentum { return .zero }
        if speed > timing.maxScrollMomentum { v = v * (timing.maxScrollMomentum / speed) }
        return v
    }

    private func endTouch(at t: Double, lifted: Bool, _ out: inout [GestureOutput]) {
        guard let ended = touch else { return }
        touch = nil
        lastRelease = t
        switch ended.kind {
        case .pinch:
            if lifted && !ended.moved && !ended.pressed && t - ended.start <= timing.maxTapDuration {
                var count = 1
                if let last = lastClick, ended.start - last.t <= timing.doubleClickInterval, !movedSinceClick {
                    count = min(3, last.count + 1)
                }
                lastClick = (t, count)
                movedSinceClick = false
                out.append(.click(count: count))
            }
            out.append(.touchEnded)
        case .threeFinger:
            let v = lifted ? releaseVelocity(at: t) : .zero
            if v != .zero { glide = (t, 0) }
            scrollTrack.removeAll()
            out.append(.scrollEnded(vx: v.x, vy: v.y))
        }
        flick.reset()
        flick.requireRest()
    }

    private func loseHand(at t: Double, _ out: inout [GestureOutput]) {
        endTouch(at: t, lifted: false, &out)
        touches.reset()
        flick.reset()
        toggle.handLost(at: t)
        flickHoldoff = nil
        filter.reset()
        history.removeAll()
        trackedSince = nil
        lastSeen = nil
        previousPalm = nil
        previousFiltered = nil
        handSize = nil
        snapshot = GestureSnapshot()
        snapshot.controlOn = controlOn
    }
}
