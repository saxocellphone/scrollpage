import Foundation

public enum GestureOutput: Equatable, Sendable {
    /// Pinch went down: the finger touched the pad.
    case touchBegan
    /// Stop the momentum glide. Sent just before a pinch or fist begins while a
    /// glide could still be running, unless it comes too soon after a fling to
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
    /// The hand closed into a fist: two fingers are on the pad. Any glide
    /// stops, since a new scroll gesture replaces it.
    case scrollBegan
    /// Content displacement in points while the fist rolls or moves, with the
    /// same signs as `fling`.
    case scrolled(dx: Double, dy: Double)
    /// The fist opened. Content velocity for the glide that follows, zero for
    /// none (a slow release, or a fist given up because the hand was lost).
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

    /// Content points per hand unit of fist motion at a moderate speed: 250 to
    /// 1000, 500 at the middle of the Scrolling speed slider. A hand unit is
    /// about 10 cm, so the default moves a page about as far as the hand moves
    /// on screen.
    public var scrollGain: Double { 250 * pow(4, clamp01(scrollingSpeed)) }
}

/// How a fist scrolls.
///
/// With the fist closed and held edge-on, rolling the forearm turns the hand's
/// wrist-to-knuckle line in the image (the palm-width ratio that measures the
/// roll of an open hand widens either way): in the user's `--calibrate-fist`
/// run it turned clockwise about 32 degrees from rest at the peak of each roll
/// palm up, and counter-clockwise about 75 degrees at each roll palm down. So
/// the fist's turn in the image is its vertical, and only moving the whole
/// hand scrolls sideways. Its wrist, not its knuckles, is followed for that:
/// the knuckles swing around the forearm as it rolls (1.25 hand sizes across
/// in the palm-up step, against 0.54 for the wrist).
public struct FistScrollConfig: Equatable, Sendable {
    /// Radians the fist turns at a full roll palm up (clockwise) and palm down
    /// (counter-clockwise): each direction is scaled to its own range.
    public var upRange = 0.6
    public var downRange = 1.25
    /// Hand units of scroll for a full roll either way.
    public var rollGain = 1.0
    /// Weight of moving the whole hand up or down, next to the roll.
    public var translationWeight = 0.5
    /// Outside a fist, the turn that counts as neutral follows the hand with
    /// this time constant, so a fist closed mid-roll scales each side right.
    public var neutralTime = 4.0
    /// Content points per hand unit for slow and for quick motion, as
    /// multiples of `MotionSettings.scrollGain`, with the pointer's curve in
    /// between.
    public var slowGain = 0.5
    public var fastGain = 2.0
    /// Below `restSpeed` (hand units per second) a fist doesn't scroll, fading
    /// in by `restBlendSpeed`. Wider than the pointer's: a fist held still
    /// jitters at 0.35 (median, 0.86 at the 95th percentile), and below 0.3 it
    /// still scrolled 26 points a second; rolls lose 3 % and moves 11 %.
    public var restSpeed = 0.3
    public var restBlendSpeed = 0.75
    /// Share of the release velocity the glide keeps.
    public var glide = 0.6

    public init() {}
}

/// What the UI needs to know about the current frame.
public struct GestureSnapshot: Equatable, Sendable {
    public var handVisible = false
    public var isOpenHand = false
    /// A pinch is down (the pointer finger).
    public var isTouching = false
    public var isPressed = false
    /// A fist scroll is under way.
    public var isScrolling = false
    /// All four fingers read curled.
    public var isFist = false
    public var pinchRatio: Double?
    public var touch = TouchMeasure()
    public var handSize: Double?
    /// Hand speed used for acceleration, in hand units per second.
    public var speed: Double = 0
    /// The pointer displacement this frame would produce if the hand were
    /// pinching. Used by diagnostics to measure drift of a still hand.
    public var potentialDelta = Vec2.zero
    /// The content displacement this frame would produce if the hand were a fist.
    public var potentialScroll = Vec2.zero
    /// Gestures drive the pointer. When false only the toggle is watched.
    public var controlOn = true
    /// Progress (0...1) of a peace-sign hold toward toggling control.
    public var toggleProgress = 0.0
    /// The peace-sign toggle fired on this frame; `controlOn` is the new state.
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
    /// Tracking gaps up to this long are bridged without ending a gesture.
    public var lostGrace = 0.15
    /// Faster palm motion (hand units per second, plus half a hand of slack)
    /// is a tracking jump, not the hand: flicks peak below 20.
    public var maxHandSpeed = 30.0
    /// After a pinch or fist ends, no flick for this long.
    public var flickAfterRelease = 0.25
    /// Thumb and index tips closer than this (hand sizes) are reaching for a
    /// pinch, not flicking: hovering tips read 0.13 to 0.23 (10th to 75th
    /// percentile), an open hand 0.3 and up.
    public var flickMinThumbIndex = 0.25
    /// A newly acquired hand must be tracked this long before it can flick.
    public var flickAfterAcquire = 0.15
    /// After a toggle, no flick until the hand has left the peace sign for this
    /// long and come to rest, so lowering the hand doesn't scroll.
    public var flickAfterToggle = 0.4
    /// A pinch or fist this soon after a fling does not stop the glide: on a
    /// webcam the hand often closes ~0.1 s after flicking, which would end the
    /// scroll almost as soon as it started.
    public var glideCatchDelay = 0.4
    /// Window over which hand speed is measured for acceleration.
    public var speedWindow = 0.08
    /// The forearm counts as rolling while its roll runs faster than this
    /// (fractions of neutral per second, `ForearmTwist.rate`), and for
    /// `rollLinger` after: a pinch then survives its tips reading apart.
    public var rollRate = 0.25
    public var rollLinger = 0.3
    /// Fist release velocity is a recency-weighted fit over this window of
    /// the last frames of the fist.
    public var scrollReleaseWindow = 0.1
    /// Releases slower than this (content points per second) don't glide.
    public var minScrollMomentum = 150.0
    public var maxScrollMomentum = 5000.0
    /// No glide if the fist took longer than this to open after its last
    /// frame: the velocity would be stale.
    public var scrollReleaseStale = 0.15

    public init() {}
}

/// Turns a stream of hand samples into trackpad-like events.
///
/// - Pinch (an "OK" sign) and move is a finger on the pad: relative pointer
///   motion, with velocity-based acceleration. Sideways, turning the hand at
///   the wrist moves the pointer too (`WristRotation`); up and down, rolling
///   the forearm does (`ForearmTwist`), with moving the hand at half weight.
/// - A quick pinch without moving is tap-to-click (double tap double-clicks).
/// - Pinch and hold still, then move, drags.
/// - A fist, rolled or moved, is two-finger scrolling: rolling the palm up
///   scrolls like fingers moving up the pad, moving the hand scrolls with it,
///   and the content glides a little on a quick release.
/// - A flick of the open hand starts a momentum scroll; a pinch or fist catches it.
/// - An open hand, or no hand, is a lifted finger: nothing moves.
/// - A peace sign (index and middle up in a V, the other fingers folded) held
///   still for half a second turns control off or back on, but never during a
///   pinch or fist. While off, nothing but that toggle is recognized.
///
/// Only a pinch confirmed by `TouchDetector` moves the pointer, and only a
/// fist confirmed by `FistDetector` scrolls.
///
/// Pure and deterministic: feed it samples with their capture timestamps.
public final class GestureEngine {
    public var settings: MotionSettings {
        didSet { updateCurves() }
    }
    public var timing: GestureTiming
    public var fistScroll = FistScrollConfig() {
        didSet { updateCurves() }
    }
    public private(set) var acceleration: PointerAcceleration
    public private(set) var scrollAcceleration: PointerAcceleration
    public private(set) var snapshot = GestureSnapshot()
    public private(set) var controlOn = true

    public var touches = TouchDetector()
    public var fist = FistDetector()
    public var filter = OneEuroFilter2D()
    public var flick = FlickDetector()
    public var toggle = ToggleGestureDetector()
    public var rotation = WristRotation()
    public var twist = ForearmTwist()
    /// Filters the pointer track the same way `filter` does the hand's motion.
    public var pointerFilter = OneEuroFilter2D()
    /// And the hand's vertical motion.
    public var liftFilter = OneEuroFilter2D()
    /// And the forearm's roll: crossing the hand's neutral roll steepens it
    /// from one frame to the next, which acceleration would amplify.
    public var rollFilter = OneEuroFilter2D()
    /// And the fist's scroll track.
    public var scrollFilter = OneEuroFilter2D()

    private struct Touch {
        var start: Double
        var origin: Vec2
        var rollOrigin: Double
        var moved = false
        var rolled = false
        var pressed = false
    }

    private var touch: Touch?
    private var handSize: Double?
    private var previousPalm: Vec2?
    private var previousWrist: Vec2?
    /// Integrated hand position in hand units. Only differences matter.
    private var virtual = Vec2.zero
    private var history: [(t: Double, p: Vec2)] = []
    /// The hand's motion plus its turn at the wrist: horizontally what a pinch
    /// moves the pointer by. Its filtered speed sets the pointer's gain.
    private var pointerVirtual = Vec2.zero
    /// The hand's vertical motion, less what turning at the wrist accounts
    /// for and without the wrist's pitch: a pinch moves the pointer by it at
    /// `ForearmTwistConfig.translationWeight`, next to the roll.
    private var liftVirtual = 0.0
    private var previousLiftFiltered: Double?
    private var previousPointerFiltered: Vec2?
    private var pointerHistory: [(t: Double, p: Vec2)] = []
    /// The forearm's roll in hand units: kept apart, so its speed never
    /// changes the horizontal gain. A pinch's tap slop measures it on its own.
    private var rollVirtual = 0.0
    private var previousRollFiltered: Double?
    private var rollHistory: [(t: Double, p: Vec2)] = []
    private var lastRoll = -Double.infinity
    /// What a fist scrolls by: horizontally the wrist's motion, vertically the
    /// fist's turn plus half the wrist's motion.
    private var scrollVirtual = Vec2.zero
    private var previousScrollFiltered: Vec2?
    private var scrollHistory: [(t: Double, p: Vec2)] = []
    /// The hand's turn from its neutral, radians clockwise: which side of rest
    /// a fist is on.
    private var fistTurn = 0.0
    private var trackedSince: Double?
    private var lastSeen: Double?
    private var lastRelease = -Double.infinity
    /// When the last glide started, and how soon after it a gesture may catch it.
    private var glide: (start: Double, catchDelay: Double)?
    private var lastClick: (t: Double, count: Int)?
    private var movedSinceClick = false
    private var scrolling = false
    /// Content offset of the fist scroll on each of its frames.
    private var scrollTrack: [(t: Double, offset: Vec2)] = []
    private var scrollOffset = Vec2.zero
    /// End of the post-toggle flick hold-off; infinite while the V is still held.
    private var flickHoldoff: Double?

    public init(settings: MotionSettings = MotionSettings(), timing: GestureTiming = GestureTiming()) {
        self.settings = settings
        self.timing = timing
        acceleration = PointerAcceleration(trackingSpeed: settings.trackingSpeed, screenWidth: settings.screenWidth)
        scrollAcceleration = Self.scrollCurve(settings, fistScroll)
    }

    private static func scrollCurve(_ s: MotionSettings, _ c: FistScrollConfig) -> PointerAcceleration {
        PointerAcceleration(slowGain: s.scrollGain * c.slowGain, fastGain: s.scrollGain * c.fastGain,
                            restSpeed: c.restSpeed, restBlendSpeed: c.restBlendSpeed)
    }

    private func updateCurves() {
        acceleration = PointerAcceleration(trackingSpeed: settings.trackingSpeed, screenWidth: settings.screenWidth)
        scrollAcceleration = Self.scrollCurve(settings, fistScroll)
    }

    /// A gesture is under way or starting (a pinch, a fist, their
    /// confirmation, or a peace-sign hold), so the hand driving it must not be
    /// swapped.
    public var isEngaged: Bool { touch != nil || touches.isEngaged || fist.isEngaged || toggle.isHolding }

    /// Ends any gesture without clicking and forgets the hand.
    public func reset() -> [GestureOutput] {
        var out: [GestureOutput] = []
        loseHand(at: lastSeen ?? 0, &out)
        return out
    }

    /// Turns control on or off from outside (the menu). Turning it off ends any
    /// gesture without clicking; with none under way, it catches any glide like
    /// a finger landing on the pad and lifting.
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

        // A palm that moved farther than a hand can is another detection, or
        // the hand found again elsewhere: start over as with a new hand, so the
        // jump never moves the pointer, scrolls or flings.
        if let prev = previousPalm, let seen = lastSeen, let size = handSize,
           palm.distance(to: prev) / size > timing.maxHandSpeed * (t - seen) + 0.5 {
            loseHand(at: t, &out)
        }
        if trackedSince == nil {
            trackedSince = t
            flick.reset()
            flick.requireRest()
        }
        let dt = lastSeen.map { t - $0 } ?? 0
        lastSeen = t

        let size = handSize.map { $0 + (rawSize - $0) * 0.2 } ?? rawSize
        handSize = size
        let turn = rotation.update(hand, handSize: size, at: t)
        let roll = twist.update(hand, at: t)
        if twist.isRolling, twist.rate > timing.rollRate * twist.noiseScale { lastRoll = t }
        let wrist = hand.location(.wrist, minConfidence: rotation.config.minConfidence)
        if let prev = previousPalm {
            let step = (palm - prev) / size
            virtual += step
            pointerVirtual += step + turn
            liftVirtual += step.y + turn.y - rotation.pitchMotion
            rollVirtual += roll
            let wristStep = wrist.flatMap { w in previousWrist.map { (w - $0) / size } } ?? step
            scrollVirtual += Vec2(wristStep.x, wristStep.y * fistScroll.translationWeight + fistRoll(rotation.yaw))
        }
        fistTurn += rotation.yaw
        if !fist.active { fistTurn -= fistTurn * min(1, dt / fistScroll.neutralTime) }
        previousPalm = palm
        previousWrist = wrist

        let filtered = filter.filter(virtual, at: t)
        let speed = measureSpeed(&history, filtered, at: t)

        let pointerFiltered = pointerFilter.filter(pointerVirtual, at: t)
        let pointerStep = previousPointerFiltered.map { pointerFiltered - $0 } ?? .zero
        previousPointerFiltered = pointerFiltered
        let pointerSpeed = measureSpeed(&pointerHistory, pointerFiltered, at: t)
        let liftFiltered = liftFilter.filter(Vec2(0, liftVirtual), at: t).y
        let liftStep = previousLiftFiltered.map { liftFiltered - $0 } ?? 0
        previousLiftFiltered = liftFiltered
        let rollFiltered = rollFilter.filter(Vec2(0, rollVirtual), at: t).y
        let rollStep = previousRollFiltered.map { rollFiltered - $0 } ?? 0
        previousRollFiltered = rollFiltered
        let rollSpeed = measureSpeed(&rollHistory, Vec2(0, rollFiltered), at: t)
        let rollDelta = Vec2(0, rollStep * acceleration.gain(forSpeed: rollSpeed))
        let translationDelta = acceleration.displacement(for: Vec2(pointerStep.x, liftStep * twist.config.translationWeight),
                                                         speed: pointerSpeed)

        let scrollFiltered = scrollFilter.filter(scrollVirtual, at: t)
        let scrollStep = previousScrollFiltered.map { scrollFiltered - $0 } ?? .zero
        previousScrollFiltered = scrollFiltered
        let scrollSpeed = measureSpeed(&scrollHistory, scrollFiltered, at: t)
        let scrollDelta = scrollAcceleration.displacement(for: scrollStep, speed: scrollSpeed)
            * (settings.naturalScrolling ? 1 : -1)

        var blocked: String?
        let toggled = toggle.update(hand, handSize: size, position: filtered, speed: speed,
                                    available: touch == nil && !touches.isEngaged && !fist.isEngaged, at: t)
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
            // Only the toggle is watched, and a gesture must start afresh.
            touches.reset()
            fist.reset()
        } else {
            let fistEvent = fist.update(hand, handSize: size, speed: speed,
                                        canStart: touch == nil && !touches.isEngaged, at: t)
            if fist.active || fistEvent != nil {
                // A pinch must start from tips seen apart after the fist.
                touches.reset()
                switch fistEvent {
                case .began:
                    catchGlide(at: t, &out)
                    glide = nil
                    scrolling = true
                    scrollOffset = .zero
                    scrollTrack = [(t, .zero)]
                    out.append(.scrollBegan)
                case let .ended(opened):
                    endScroll(at: t, opened: opened, &out)
                case nil:
                    scrollOffset += scrollDelta
                    scrollTrack.append((t, scrollOffset))
                    while let first = scrollTrack.first, t - first.t > 2 * timing.scrollReleaseWindow { scrollTrack.removeFirst() }
                    if scrollDelta != .zero { out.append(.scrolled(dx: scrollDelta.x, dy: scrollDelta.y)) }
                }
            } else {
                switch touches.update(hand, handSize: size, rolling: t - lastRoll <= timing.rollLinger, at: t) {
                case .began:
                    catchGlide(at: t, &out)
                    touch = Touch(start: t, origin: pointerFiltered, rollOrigin: rollVirtual)
                    twist.engaged = true
                    out.append(.touchBegan)
                case let .ended(lifted):
                    endTouch(at: t, lifted: lifted, &out)
                case nil:
                    if let current = touch {
                        continueTouch(current, pointer: pointerFiltered,
                                      translation: touches.heldThroughRoll ? .zero : translationDelta,
                                      rollDelta: rollDelta, at: t, &out)
                    } else {
                        blocked = watchFlick(hand, speed: speed, at: t, &out)
                    }
                }
            }
        }

        snapshot = GestureSnapshot()
        snapshot.handVisible = true
        snapshot.isOpenHand = hand.isOpenHand
        snapshot.isTouching = touch != nil
        snapshot.isPressed = touch?.pressed ?? false
        snapshot.isScrolling = scrolling
        snapshot.isFist = fist.fingers.curled.count == Finger.allCases.count
        snapshot.pinchRatio = touches.measure.thumbIndex
        snapshot.touch = touches.measure
        snapshot.handSize = size
        snapshot.speed = speed
        snapshot.potentialDelta = translationDelta + rollDelta
        snapshot.potentialScroll = scrollDelta
        snapshot.controlOn = controlOn
        snapshot.toggleProgress = toggle.progress
        snapshot.toggled = toggled
        snapshot.flickBlocked = blocked
        return out
    }

    /// Vertical scroll in hand units (y-down) for the fist turning `yaw`
    /// radians clockwise: palm up turns it clockwise and scrolls up.
    private func fistRoll(_ yaw: Double) -> Double {
        guard yaw != 0 else { return 0 }
        let range = fistTurn + yaw * 0.5 > 0 ? fistScroll.upRange : fistScroll.downRange
        return -yaw / range * fistScroll.rollGain
    }

    /// A pinch or fist lands: it stops a glide, unless that glide was flung
    /// too recently to be caught on purpose. (A fist's scroll replaces the
    /// glide anyway.)
    private func catchGlide(at t: Double, _ out: inout [GestureOutput]) {
        flick.reset()
        if let g = glide, t - g.start >= g.catchDelay, t - g.start <= MomentumScroller().maxGlideDuration {
            out.append(.catchGlide)
            glide = nil
        }
    }

    /// The hand's motion and the forearm's roll each leave the tap slop on
    /// their own: either ends the tap, the roll then moves the pointer, and
    /// the hand's motion only once it has left the slop itself, as without
    /// the roll.
    private func continueTouch(_ current: Touch, pointer: Vec2, translation: Vec2, rollDelta: Vec2,
                               at t: Double, _ out: inout [GestureOutput]) {
        var current = current
        defer { touch = current }
        if !current.moved && pointer.distance(to: current.origin) > timing.tapSlop {
            current.moved = true
        }
        if !current.rolled && abs(rollVirtual - current.rollOrigin) > timing.tapSlop {
            current.rolled = true
        }
        if !current.moved && !current.rolled && !current.pressed && t - current.start >= timing.pressDelay {
            current.pressed = true
            out.append(.pressBegan)
        }
        let delta = (current.moved ? translation : .zero) + (current.moved || current.rolled ? rollDelta : .zero)
        if touches.canMove && delta != .zero {
            movedSinceClick = true
            out.append(.pointerMoved(dx: delta.x, dy: delta.y))
        }
    }

    private func watchFlick(_ hand: HandSample, speed: Double, at t: Double, _ out: inout [GestureOutput]) -> String? {
        var blocked: String?
        let afterRelease = t - lastRelease >= timing.flickAfterRelease
        let afterAcquire = t - (trackedSince ?? t) >= timing.flickAfterAcquire
        let afterToggle = flickHoldoff == nil
        let m = touches.measure
        let reaching = m.readable && (m.thumbIndex ?? .infinity) < timing.flickMinThumbIndex
        if !flick.inStroke && speed > flick.config.startSpeed {
            if !hand.isOpenHand {
                blocked = "hand not open (\(hand.extendedFingerCount) fingers)"
            } else if reaching {
                blocked = "thumb near the index"
            } else if !afterRelease {
                blocked = "just released a gesture"
            } else if !afterAcquire {
                blocked = "hand just appeared"
            } else if !afterToggle {
                blocked = "just toggled control"
            }
        }
        let mayFlick = afterRelease && afterAcquire && afterToggle && hand.isOpenHand && !reaching
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
            if touch == nil && !scrolling {
                out += [.catchGlide, .touchBegan, .touchEnded]
            } else {
                endTouch(at: t, lifted: false, &out)
                endScroll(at: t, opened: false, &out)
            }
            glide = nil
            lastClick = nil
        }
        touches.reset()
        fist.reset()
        flick.reset()
        flick.requireRest()
    }

    /// Speed over the last ~80 ms of filtered motion. A per-frame difference is
    /// too noisy to pick the acceleration gain from.
    private func measureSpeed(_ history: inout [(t: Double, p: Vec2)], _ p: Vec2, at t: Double) -> Double {
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
    /// `scrollReleaseWindow` of the fist, newer frames weighted up to twice
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
        var v = num / den * fistScroll.glide
        let speed = v.length
        if speed < timing.minScrollMomentum { return .zero }
        if speed > timing.maxScrollMomentum { v = v * (timing.maxScrollMomentum / speed) }
        return v
    }

    private func endTouch(at t: Double, lifted: Bool, _ out: inout [GestureOutput]) {
        guard let ended = touch else { return }
        touch = nil
        twist.engaged = false
        lastRelease = t
        if lifted && !ended.moved && !ended.rolled && !ended.pressed && t - ended.start <= timing.maxTapDuration {
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

    private func endScroll(at t: Double, opened: Bool, _ out: inout [GestureOutput]) {
        guard scrolling else { return }
        scrolling = false
        lastRelease = t
        let v = opened ? releaseVelocity(at: t) : .zero
        if v != .zero { glide = (t, 0) }
        scrollTrack.removeAll()
        out.append(.scrollEnded(vx: v.x, vy: v.y))
        flick.reset()
        flick.requireRest()
    }

    private func loseHand(at t: Double, _ out: inout [GestureOutput]) {
        endTouch(at: t, lifted: false, &out)
        endScroll(at: t, opened: false, &out)
        touches.handLost(at: t)
        fist.handLost(at: t)
        flick.reset()
        toggle.handLost(at: t)
        flickHoldoff = nil
        filter.reset()
        history.removeAll()
        rotation.reset()
        twist.reset()
        lastRoll = -.infinity
        pointerFilter.reset()
        pointerHistory.removeAll()
        previousPointerFiltered = nil
        liftFilter.reset()
        previousLiftFiltered = nil
        rollFilter.reset()
        previousRollFiltered = nil
        rollHistory.removeAll()
        scrollFilter.reset()
        scrollHistory.removeAll()
        previousScrollFiltered = nil
        fistTurn = 0
        trackedSince = nil
        lastSeen = nil
        previousPalm = nil
        previousWrist = nil
        handSize = nil
        snapshot = GestureSnapshot()
        snapshot.controlOn = controlOn
    }
}
