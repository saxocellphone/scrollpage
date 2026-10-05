import Foundation

/// When a hand's shape counts as a peace sign: index and middle up in a V,
/// ring and little curled, thumb folded over them.
///
/// Distances are in hand sizes (wrist to middle knuckle). Each measure has an
/// enter tolerance and a looser one for staying in the pose, so a held V
/// doesn't flicker. Figures are from seven webcam recordings (about 3,500 right-
/// hand frames, none of them a peace sign); the V itself was measured on the
/// synthetic hand, so the enter tolerances sit well inside what it reads.
public struct PeaceSignThresholds: Equatable, Sendable {
    /// Index tip to middle tip. Fingers held together read 0.10 to 0.25 (their
    /// knuckles are 0.2 apart), a V about 0.5.
    public var gapEnter = 0.30
    public var gapExit = 0.24
    /// Angle between index and middle, knuckle to tip, in degrees. A V opens
    /// 20 to 40; fingers side by side read under 10.
    public var angleEnter = 12.0
    public var angleExit = 8.0
    /// How far each of the two tips lies past its knuckle along the hand
    /// (wrist to middle knuckle). Upright fingers read 0.6 to 0.9; a curled
    /// finger never more than 0.27, even when it reads as straight for a frame.
    public var reachEnter = 0.35
    public var reachExit = 0.30
    /// Thumb tip to the nearest of the ring and little middle joints and the
    /// palm center. A thumb folded over the curled fingers reads 0.21 to 0.31,
    /// one held beside the hand 0.5 to 0.8, one stretched out about 1.
    public var thumbNearEnter = 0.45
    public var thumbNearExit = 0.55
    /// Thumb tip to the index and middle tips: about 0.1 while they touch,
    /// about 1 with the thumb folded under a V.
    public var thumbApartEnter = 0.40
    public var thumbApartExit = 0.33
    /// How far the thumb tip lies across the palm from the index knuckle,
    /// along the knuckle line toward the little finger; negative is out to the
    /// side. Folded thumbs read 0.37 to 0.52, relaxed ones -0.2 to -0.7.
    public var thumbAcrossEnter = 0.0
    public var thumbAcrossExit = -0.08
    public var minConfidence = 0.3
    public var fingers = ExtensionThresholds()

    public init() {}
}

/// The geometry the peace sign is judged on, in hand sizes and degrees; nil
/// where the joints aren't seen well enough.
public struct PeaceSignMeasure: Equatable, Sendable {
    public var gap: Double?
    public var angle: Double?
    /// The smaller of the index and middle reach.
    public var reach: Double?
    public var thumbNear: Double?
    /// The thumb tip's distance to the nearer of the index and middle tips.
    public var thumbApart: Double?
    public var thumbAcross: Double?

    public init() {}

    public init(_ hand: HandSample, handSize size: Double, minConfidence: Double = 0.3) {
        guard size > 0 else { return }
        func at(_ j: HandJoint) -> Vec2? { hand.location(j, minConfidence: minConfidence) }
        let indexMCP = at(.indexMCP), middleMCP = at(.middleMCP), indexTip = at(.indexTip), middleTip = at(.middleTip)
        if let indexTip, let middleTip { gap = indexTip.distance(to: middleTip) / size }
        if let indexMCP, let middleMCP, let indexTip, let middleTip {
            let a = indexTip - indexMCP, b = middleTip - middleMCP
            let n = a.length * b.length
            if n > 1e-12 { angle = acos(max(-1, min(1, a.dot(b) / n))) * 180 / .pi }
        }
        let wrist = at(.wrist)
        if let wrist, let middleMCP, let indexMCP, let indexTip, let middleTip, wrist.distance(to: middleMCP) > 1e-9 {
            let up = (middleMCP - wrist) / wrist.distance(to: middleMCP)
            reach = min((indexTip - indexMCP).dot(up), (middleTip - middleMCP).dot(up)) / size
        }
        guard let thumb = at(.thumbTip) else { return }
        let anchors = [at(.ringPIP), at(.littlePIP), hand.palmCenter].compactMap { $0 }
        if !anchors.isEmpty { thumbNear = anchors.map { thumb.distance(to: $0) }.min()! / size }
        let tips = [indexTip, middleTip].compactMap { $0 }
        if tips.count == 2 { thumbApart = tips.map { thumb.distance(to: $0) }.min()! / size }
        if let indexMCP, let littleMCP = at(.littleMCP), indexMCP.distance(to: littleMCP) > 1e-9 {
            let across = (littleMCP - indexMCP) / indexMCP.distance(to: littleMCP)
            thumbAcross = (thumb - indexMCP).dot(across) / size
        }
    }

    /// The V and the thumb, with the enter tolerances or, `holding` the pose,
    /// the exit ones. The fingers' extended and curled states are judged apart.
    public func matches(_ th: PeaceSignThresholds, holding: Bool) -> Bool {
        guard let gap, let angle, let reach, let thumbNear, let thumbApart, let thumbAcross else { return false }
        return gap >= (holding ? th.gapExit : th.gapEnter)
            && angle >= (holding ? th.angleExit : th.angleEnter)
            && reach >= (holding ? th.reachExit : th.reachEnter)
            && thumbNear <= (holding ? th.thumbNearExit : th.thumbNearEnter)
            && thumbApart >= (holding ? th.thumbApartExit : th.thumbApartEnter)
            && thumbAcross >= (holding ? th.thumbAcrossExit : th.thumbAcrossEnter)
    }
}

public struct ToggleGestureConfig: Equatable, Sendable {
    /// How long the peace sign must be held still. In the recordings no still
    /// stretch passes for longer than 0.2 s even with any one pose rule dropped.
    public var holdDuration = 0.5
    /// Progress is reported only after this much of the hold, so a hand passing
    /// through the pose shows nothing.
    public var progressDelay = 0.25
    /// Hand speed (hand units/s) above which the hold restarts. Flicks start at
    /// 1.5 and peak above 3.5, so a fast V never counts.
    public var maxSpeed = 0.4
    /// How far (hand units) the hand may wander during the hold.
    public var maxDrift = 0.15
    /// Frames in a row the pose must read before it counts.
    public var confirmFrames = 3
    /// Pose dropouts up to this long don't restart the hold.
    public var poseGrace = 0.12
    /// After a toggle the hand must leave the pose (or the frame) this long
    /// before another toggle can start.
    public var releaseTime = 0.3
    /// Minimum time between two toggles, however quickly the V is made again.
    public var refractory = 1.5
    public var pose = PeaceSignThresholds()

    public init() {}
}

/// Recognizes the control toggle: a peace sign held still for half a second.
///
/// Index and middle must be extended (with the `FingerExtensionTracker`'s
/// hysteresis) and spread in a V, ring and little curled, and the thumb folded
/// over them, away from the two raised tips, so neither three tips together,
/// a fist, an OK sign nor an open hand can pass for it. It is reported once per hold,
/// and only from a fresh entry into the pose.
public struct ToggleGestureDetector: Sendable {
    public var config: ToggleGestureConfig
    /// 0 until the hold passes `progressDelay`, then rises to 1 at the toggle.
    public private(set) var progress = 0.0
    /// The hand is in the peace-sign pose (confirmed, dropouts bridged).
    public private(set) var inPose = false
    /// A still hold of the pose is being timed.
    public var isHolding: Bool { holdStart != nil }
    public private(set) var fingers: FingerExtensionTracker
    public private(set) var measure = PeaceSignMeasure()

    private var streak = 0
    private var streakStart: Double?
    private var holdStart: Double?
    private var anchor: Vec2?
    private var lastInPose: Double?
    private var outOfPoseSince: Double?
    private var armed = true
    private var lastToggle = -Double.infinity

    public init(config: ToggleGestureConfig = ToggleGestureConfig()) {
        self.config = config
        fingers = FingerExtensionTracker(thresholds: config.pose.fingers)
    }

    /// The pose on this frame alone, without hysteresis: what diagnostics count.
    public func isPeaceSign(_ hand: HandSample, handSize size: Double) -> Bool {
        let th = config.pose
        let reading = { (f: Finger) in hand.extensionReading(f, thresholds: th.fingers) }
        return reading(.index) == .extended && reading(.middle) == .extended
            && reading(.ring) == .curled && reading(.little) == .curled
            && PeaceSignMeasure(hand, handSize: size, minConfidence: th.minConfidence).matches(th, holding: false)
    }

    /// Forget any hold in progress (the hand was lost).
    public mutating func handLost(at t: Double) {
        if outOfPoseSince == nil { outOfPoseSince = min(t, lastInPose ?? t) }
        rearmIfReleased(at: t)
        fingers.reset()
        measure = PeaceSignMeasure()
        streak = 0
        streakStart = nil
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
    /// speed in hand units per second. With `available` false (a touch is down
    /// or confirming) the pose doesn't count. Returns true on the frame the
    /// toggle fires.
    public mutating func update(_ hand: HandSample, handSize: Double, position: Vec2, speed: Double,
                                available: Bool = true, at t: Double) -> Bool {
        fingers.update(hand)
        measure = PeaceSignMeasure(hand, handSize: handSize, minConfidence: config.pose.minConfidence)
        let shaped = available
            && fingers.isExtended(.index) && fingers.isExtended(.middle)
            && fingers.isCurled(.ring) && fingers.isCurled(.little)
            && measure.matches(config.pose, holding: inPose)
        if shaped {
            if streak == 0 { streakStart = t }
            streak += 1
        } else {
            streak = 0
        }
        // Entering takes `confirmFrames` in a row; once in, a frame is enough.
        let confirmed = shaped && (inPose || streak >= config.confirmFrames)
        if confirmed { lastInPose = t }
        let bridging = !confirmed && available && lastInPose.map { t - $0 <= config.poseGrace } == true
        let entering = confirmed && !inPose
        inPose = confirmed || bridging

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
            holdStart = entering ? (streakStart ?? t) : t
            anchor = position
        }

        let held = t - (holdStart ?? t)
        if held >= config.holdDuration - 1e-9 && t - lastToggle >= config.refractory {
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
