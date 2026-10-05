import Foundation

public enum GestureOutput: Equatable, Sendable {
    /// Pinch went down: the finger touched the pad.
    case touchBegan
    /// Stop the momentum glide. Sent just before `touchBegan` while a glide
    /// could still be running, unless the pinch comes too soon after the fling
    /// to be a deliberate catch.
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
}

/// What the UI needs to know about the current frame.
public struct GestureSnapshot: Equatable, Sendable {
    public var handVisible = false
    public var isOpenHand = false
    public var isTouching = false
    public var isPressed = false
    public var pinchRatio: Double?
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
    /// Once the fingers start opening past this ratio the pointer is frozen, so
    /// the jitter of letting go never moves it.
    public var releaseFreezeRatio = 0.30
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

    public init() {}
}

/// Turns a stream of hand samples into trackpad-like events.
///
/// - Pinch and move is a finger on the pad: relative pointer motion, with
///   velocity-based acceleration.
/// - A quick pinch without moving is tap-to-click (double tap double-clicks).
/// - Pinch and hold still, then move, drags.
/// - A flick of the open hand starts a momentum scroll; a pinch catches it.
/// - An open hand, or no hand, is a lifted finger: nothing moves.
/// - A raised palm, five fingers spread, held still for a second turns control
///   off or back on. While off, nothing but that toggle is recognized.
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

    public var pinch = PinchDetector()
    public var filter = OneEuroFilter2D()
    public var flick = FlickDetector()
    public var toggle = ToggleGestureDetector()

    private struct Touch {
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
    private var lastFling = -Double.infinity
    private var lastClick: (t: Double, count: Int)?
    private var movedSinceClick = false
    /// A touch only begins after the fingers have been seen apart, so a hand
    /// that arrives already closed (or a fist read as a pinch) never grabs the pointer.
    private var pinchArmed = false
    /// End of the post-toggle flick hold-off; infinite while the palm is still raised.
    private var flickHoldoff: Double?

    public init(settings: MotionSettings = MotionSettings(), timing: GestureTiming = GestureTiming()) {
        self.settings = settings
        self.timing = timing
        self.acceleration = PointerAcceleration(trackingSpeed: settings.trackingSpeed, screenWidth: settings.screenWidth)
    }

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
        let ratio = hand.pinchRatio(handSize: size)
        let wasPinching = pinch.isPinching
        let pinching = pinch.update(ratio)
        if let ratio, ratio > pinch.releaseRatio { pinchArmed = true }

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
            // Only the toggle is watched.
        } else if pinching && !wasPinching && pinchArmed {
            pinchArmed = false
            touch = Touch(start: t, origin: filtered)
            flick.reset()
            let sinceFling = t - lastFling
            if sinceFling >= timing.glideCatchDelay && sinceFling <= MomentumScroller().maxGlideDuration {
                out.append(.catchGlide)
            }
            out.append(.touchBegan)
        } else if !pinching && wasPinching {
            endTouch(at: t, allowClick: true, &out)
        } else if pinching, var current = touch {
            if !current.moved && filtered.distance(to: current.origin) > timing.tapSlop {
                current.moved = true
            }
            if !current.moved && !current.pressed && t - current.start >= timing.pressDelay {
                current.pressed = true
                out.append(.pressBegan)
            }
            let opening = (ratio ?? 0) > timing.releaseFreezeRatio
            if current.moved && !opening && pointerDelta != .zero {
                movedSinceClick = true
                out.append(.pointerMoved(dx: pointerDelta.x, dy: pointerDelta.y))
            }
            touch = current
        } else if !pinching && touch == nil {
            let afterRelease = t - lastRelease >= timing.flickAfterRelease
            let afterAcquire = t - (trackedSince ?? t) >= timing.flickAfterAcquire
            let afterToggle = flickHoldoff == nil
            if !flick.inStroke && speed > flick.config.startSpeed {
                if !hand.isOpenHand {
                    blocked = "hand not open (\(hand.extendedFingerCount) fingers)"
                } else if !afterRelease {
                    blocked = "just released a pinch"
                } else if !afterAcquire {
                    blocked = "hand just appeared"
                } else if !afterToggle {
                    blocked = "just toggled control"
                }
            }
            let mayFlick = afterRelease && afterAcquire && afterToggle && hand.isOpenHand
            if let f = flick.update(position: virtual, at: t, canStart: mayFlick) {
                lastFling = t
                out.append(fling(for: f))
            }
        }

        snapshot = GestureSnapshot()
        snapshot.handVisible = true
        snapshot.isOpenHand = hand.isOpenHand
        snapshot.isTouching = touch != nil
        snapshot.isPressed = touch?.pressed ?? false
        snapshot.pinchRatio = ratio
        snapshot.handSize = size
        snapshot.speed = speed
        snapshot.potentialDelta = pointerDelta
        snapshot.controlOn = controlOn
        snapshot.toggleProgress = toggle.progress
        snapshot.toggled = toggled
        snapshot.flickBlocked = blocked
        return out
    }

    private func applyControl(_ on: Bool, at t: Double, _ out: inout [GestureOutput]) {
        guard on != controlOn else { return }
        controlOn = on
        if !on {
            if touch == nil {
                out += [.catchGlide, .touchBegan, .touchEnded]
            } else {
                endTouch(at: t, allowClick: false, &out)
            }
            lastClick = nil
        }
        pinchArmed = false
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

    private func endTouch(at t: Double, allowClick: Bool, _ out: inout [GestureOutput]) {
        guard let ended = touch else { return }
        touch = nil
        lastRelease = t
        if allowClick && !ended.moved && !ended.pressed && t - ended.start <= timing.maxTapDuration {
            var count = 1
            if let last = lastClick, ended.start - last.t <= timing.doubleClickInterval, !movedSinceClick {
                count = min(3, last.count + 1)
            }
            lastClick = (t, count)
            movedSinceClick = false
            out.append(.click(count: count))
        }
        out.append(.touchEnded)
        flick.reset()
        flick.requireRest()
    }

    private func loseHand(at t: Double, _ out: inout [GestureOutput]) {
        endTouch(at: t, allowClick: false, &out)
        pinch.reset()
        pinchArmed = false
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
