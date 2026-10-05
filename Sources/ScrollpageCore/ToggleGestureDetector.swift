import Foundation

public struct ToggleGestureConfig: Equatable, Sendable {
    /// How long the raised palm must be held still.
    public var holdDuration = 1.0
    /// Progress is reported only after this much of the hold, so a palm passing
    /// through the pose shows nothing.
    public var progressDelay = 0.3
    /// Hand speed (hand units/s) above which the hold restarts. Flicks start at
    /// 1.5 and peak above 3.5, so a flick through the pose never counts.
    public var maxSpeed = 0.4
    /// How far (hand units) the hand may wander during the hold.
    public var maxDrift = 0.2
    /// Single-frame pose dropouts up to this long don't restart the hold.
    public var poseGrace = 0.12
    /// After a toggle the hand must leave the pose (or the frame) this long
    /// before another toggle can start.
    public var releaseTime = 0.3
    /// Minimum time between two toggles, however quickly the palm is raised again.
    public var refractory = 1.5

    // Pose thresholds, in hand sizes (wrist to middle knuckle).
    /// Thumb tip to index knuckle: about 0.5 relaxed, 0.8–0.9 spread.
    public var minThumbSpread = 0.65
    /// Index tip to little tip: about 0.5 with fingers together, 0.9 spread.
    public var minFingerSpread = 0.75
    /// Wrist-to-knuckles direction within this angle of straight up.
    public var maxTiltDegrees = 35.0

    public init() {}
}

/// Recognizes the control toggle: a raised open palm with all five fingers
/// spread, held still for about a second.
///
/// The ordinary open hand means "finger lifted", so the toggle asks for more:
/// thumb out, fingers spread, hand upright, still, and a fresh entry into the
/// pose after each toggle. It is reported once per hold.
public struct ToggleGestureDetector: Sendable {
    public var config: ToggleGestureConfig
    /// 0 until the hold passes `progressDelay`, then rises to 1 at the toggle.
    public private(set) var progress = 0.0
    /// The last hand seen was in the raised-palm pose (dropouts bridged).
    public private(set) var inPose = false

    private var holdStart: Double?
    private var anchor: Vec2?
    private var lastInPose: Double?
    private var outOfPoseSince: Double?
    private var armed = true
    private var lastToggle = -Double.infinity

    public init(config: ToggleGestureConfig = ToggleGestureConfig()) {
        self.config = config
    }

    public func isRaisedPalm(_ hand: HandSample, handSize size: Double) -> Bool {
        guard size > 0,
              let wrist = hand.location(.wrist), let middle = hand.location(.middleMCP),
              let indexMCP = hand.location(.indexMCP),
              let thumbTip = hand.location(.thumbTip), let thumbIP = hand.location(.thumbIP),
              let indexTip = hand.location(.indexTip), let littleTip = hand.location(.littleTip) else { return false }
        guard hand.extendedFingerCount == 4 else { return false }
        guard thumbTip.distance(to: indexMCP) / size >= config.minThumbSpread,
              wrist.distance(to: thumbTip) > wrist.distance(to: thumbIP) else { return false }
        guard indexTip.distance(to: littleTip) / size >= config.minFingerSpread else { return false }
        let up = middle - wrist
        guard up.y < 0 else { return false }
        let tilt = atan2(abs(up.x), -up.y) * 180 / .pi
        return tilt <= config.maxTiltDegrees
    }

    /// Forget any hold in progress (the hand was lost).
    public mutating func handLost(at t: Double) {
        if outOfPoseSince == nil { outOfPoseSince = min(t, lastInPose ?? t) }
        rearmIfReleased(at: t)
        holdStart = nil
        anchor = nil
        lastInPose = nil
        progress = 0
        inPose = false
    }

    private mutating func rearmIfReleased(at t: Double) {
        if let since = outOfPoseSince, t - since >= config.releaseTime { armed = true }
    }

    /// `position` is the filtered hand position in hand units and `speed` its
    /// speed in hand units per second. Returns true on the frame the toggle fires.
    public mutating func update(_ hand: HandSample, handSize: Double, position: Vec2, speed: Double, at t: Double) -> Bool {
        let posed = isRaisedPalm(hand, handSize: handSize)
        if posed { lastInPose = t }
        let bridging = !posed && lastInPose.map { t - $0 <= config.poseGrace } == true
        inPose = posed || bridging

        guard inPose else {
            holdStart = nil
            anchor = nil
            progress = 0
            if outOfPoseSince == nil { outOfPoseSince = lastInPose ?? t }
            rearmIfReleased(at: t)
            return false
        }
        rearmIfReleased(at: t)
        outOfPoseSince = nil

        guard armed else {
            progress = 0
            return false
        }

        let wandered = anchor.map { position.distance(to: $0) > config.maxDrift } ?? false
        if speed > config.maxSpeed || wandered {
            holdStart = nil
            anchor = nil
            progress = 0
            return false
        }
        if holdStart == nil {
            holdStart = t
            anchor = position
        }

        let held = t - (holdStart ?? t)
        if held >= config.holdDuration && t - lastToggle >= config.refractory {
            armed = false
            lastToggle = t
            holdStart = nil
            anchor = nil
            progress = 0
            return true
        }
        progress = held < config.progressDelay ? 0
            : min(1, (held - config.progressDelay) / (config.holdDuration - config.progressDelay))
        return false
    }
}
