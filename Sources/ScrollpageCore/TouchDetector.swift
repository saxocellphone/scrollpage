import Foundation

/// Contact thresholds in hand sizes (wrist to middle knuckle).
///
/// From the user's two `--calibrate-pinch` runs on a 1080p USB webcam at 30 fps
/// (settled frames, after each step's first 1.5 s): a held thumb–index touch
/// reads 0.05–0.07 median with its 90th percentile near 0.10, while hovering a
/// hair apart reads 0.10 median at its tightest. Earlier recordings agree
/// (touching 0.026 median, hovering 0.13 at the 10th percentile). Entering
/// below where hovering starts and leaving above where touching ends means a
/// near-touch never counts and a held touch never flickers.
public struct TouchThresholds: Equatable, Sendable {
    /// Thumb and index tips touch below this. 0.09 already starts on the
    /// tightest hover.
    public var pinchEnter = 0.08
    /// A pinch lets go above this.
    public var pinchExit = 0.12
    /// Above this the fingers are parting, so the pointer stops and letting go
    /// can't move it.
    public var pinchMoveMax = 0.10
    /// A pinch needs the middle tip at least this far from the thumb and index
    /// tips: in the OK sign it stands clear of them (0.52 or more in calibration).
    public var middleApart = 0.18
    /// Thumb and index tips seen with less confidence don't count.
    public var minTipConfidence = 0.4
    /// Nor does a middle tip seen with less.
    public var minMiddleTipConfidence = 0.3
    /// Nor do frames whose hand size comes from joints seen with less.
    public var minSizeConfidence = 0.3
    /// Consecutive frames the pose must hold before the pinch begins
    /// (0.1 s at 30 fps).
    public var confirmFrames = 3
    /// Frames off the pose but still inside the exit threshold that
    /// confirmation tolerates without starting over.
    public var confirmNoiseFrames = 2
    /// Consecutive frames clearly apart before a pinch ends.
    public var releaseFrames = 2
    /// While the forearm rolls, a pinch whose tips read apart holds this long
    /// (from the first frame apart) before it ends, without a click: rolling
    /// the palm down and back opens the tips to 0.25–0.37 on the webcam for a
    /// few frames while they still touch. Only if the roll was under way when
    /// they parted (opening the hand spreads the knuckles, which reads as a
    /// roll), and only while they stay within `rollHoldApart`: a real release
    /// passes 0.4 within a few frames.
    public var rollHold = 0.55
    public var rollHoldApart = 0.40
    /// During a pinch, frames that can't be read (fingertips hidden or
    /// uncertain) hold it this long; after that it ends without a click.
    public var unreadableGrace = 0.2
    /// Fingers seen apart before the hand was lost still count if it comes
    /// back within this long, so a tracking dropout doesn't swallow a pinch.
    public var armedAfterLoss = 0.5
    /// When the fingers that must stay extended count as extended or curled.
    public var fingers = ExtensionThresholds()
    /// During a pinch, one of those fingers may curl this long (the pinch
    /// pauses but holds, so a drag survives a twitch); after that it ends
    /// without a click.
    public var curlGrace = 0.3

    public init() {}
}

/// Fingertip distances in hand sizes for one frame.
public struct TouchMeasure: Equatable, Sendable {
    public var thumbIndex: Double?
    public var thumbMiddle: Double?
    public var indexMiddle: Double?
    /// Thumb and index tips and the hand-size joints are confident.
    public var readable = false
    /// So is the middle tip.
    public var middleReadable = false
    /// Fingers extended, and fingers curled. `TouchDetector` fills these from
    /// its hysteresis; measured on their own they come from this frame alone.
    public var extended: Set<Finger> = []
    public var curled: Set<Finger> = []

    public init(thumbIndex: Double? = nil, thumbMiddle: Double? = nil, indexMiddle: Double? = nil,
                readable: Bool = false, middleReadable: Bool = false,
                extended: Set<Finger> = [], curled: Set<Finger> = []) {
        self.thumbIndex = thumbIndex
        self.thumbMiddle = thumbMiddle
        self.indexMiddle = indexMiddle
        self.readable = readable
        self.middleReadable = middleReadable
        self.extended = extended
        self.curled = curled
    }

    /// The middle tip's distance to the nearer of the thumb and index tips.
    public var middleGap: Double? {
        guard let b = thumbMiddle, let c = indexMiddle else { return nil }
        return min(b, c)
    }

    public init(_ hand: HandSample, handSize size: Double, thresholds: TouchThresholds = TouchThresholds()) {
        func confident(_ j: HandJoint, _ minimum: Double) -> Bool { (hand[j]?.confidence ?? 0) >= minimum }
        thumbIndex = hand.ratio(.thumbTip, .indexTip, handSize: size)
        thumbMiddle = hand.ratio(.thumbTip, .middleTip, handSize: size)
        indexMiddle = hand.ratio(.indexTip, .middleTip, handSize: size)
        readable = thumbIndex != nil
            && confident(.thumbTip, thresholds.minTipConfidence) && confident(.indexTip, thresholds.minTipConfidence)
            && (hand.handSizeConfidence ?? 0) >= thresholds.minSizeConfidence
        middleReadable = readable && thumbMiddle != nil && confident(.middleTip, thresholds.minMiddleTipConfidence)
        for finger in Finger.allCases {
            switch hand.extensionReading(finger, thresholds: thresholds.fingers) {
            case .extended: extended.insert(finger)
            case .curled: curled.insert(finger)
            case .between, .unreadable: break
            }
        }
    }
}

public enum TouchEvent: Equatable, Sendable {
    case began
    /// `lifted` is true when the fingertips were seen to part (a tap can
    /// click), false when the pinch was given up: its tips couldn't be read, a
    /// lifted finger stayed curled, or it outlasted a roll.
    case ended(lifted: Bool)
}

/// Decides when the thumb and index tips touch in an OK sign: one finger on
/// the pad.
///
/// A pinch begins only after the thumb and index tips have been seen apart
/// (the frame a pinch lets go counts), and then showed the pose on
/// `confirmFrames` frames, with at most `confirmNoiseFrames` in between that
/// stay inside the exit threshold and none that leave it or can't be read. The
/// pose includes the middle, ring and little fingers (`liftedFingers`) being
/// extended, so a fist or a half-closed hand never touches. If one of them
/// curls, the pinch pauses; curled for longer than `curlGrace`, it ends
/// without a click.
public struct TouchDetector: Sendable {
    /// The fingers that must stay extended, off the pad.
    public static let liftedFingers: Set<Finger> = [.middle, .ring, .little]

    public var thresholds: TouchThresholds

    /// A pinch is down.
    public private(set) var active = false
    /// The pose is being confirmed before a pinch begins.
    public private(set) var pending = false
    /// The tips are firmly in contact this frame, so the pinch may move the pointer.
    public private(set) var canMove = false
    public private(set) var measure = TouchMeasure()
    public private(set) var fingers: FingerExtensionTracker

    private var pendingFrames = 0
    private var pendingNoise = 0
    private var releaseCount = 0
    private var apartSince: Double?
    /// The tips read apart but the pinch is held because the forearm is rolling:
    /// only the roll should move the pointer.
    public private(set) var heldThroughRoll = false
    private var rollingWhenApart = false
    private var unreadableSince: Double?
    private var curledSince: Double?
    private var armed = false
    private var armedUntil: Double?

    public init(thresholds: TouchThresholds = TouchThresholds()) {
        self.thresholds = thresholds
        fingers = FingerExtensionTracker(thresholds: thresholds.fingers)
    }

    /// A pinch is down or being confirmed.
    public var isEngaged: Bool { active || pending }

    /// Forgets everything, including that the fingers were seen apart.
    public mutating func reset() {
        active = false
        pending = false
        pendingFrames = 0
        pendingNoise = 0
        endTouch()
        fingers.reset()
        armed = false
        armedUntil = nil
    }

    /// The hand left: any pinch is over (the caller ends it), but fingers
    /// already seen apart stay so for `armedAfterLoss`.
    public mutating func handLost(at t: Double) {
        let until = armed ? t + thresholds.armedAfterLoss : armedUntil
        reset()
        armedUntil = until
    }

    /// Whether this frame shows the pinch pose, ignoring confirmation and arming.
    public func isPinch(_ m: TouchMeasure) -> Bool {
        guard m.readable, let ti = m.thumbIndex, ti <= thresholds.pinchEnter,
              m.middleReadable, let gap = m.middleGap, gap >= thresholds.middleApart else { return false }
        return Self.liftedFingers.isSubset(of: m.extended)
    }

    /// `rolling`: the forearm is rolling, so a pinch whose tips read apart
    /// holds for up to `rollHold` (see there).
    public mutating func update(_ hand: HandSample, handSize: Double, rolling: Bool = false, at t: Double) -> TouchEvent? {
        var m = TouchMeasure(hand, handSize: handSize, thresholds: thresholds)
        fingers.thresholds = thresholds.fingers
        fingers.update(hand)
        m.extended = fingers.extended
        m.curled = fingers.curled
        measure = m
        canMove = false
        if let until = armedUntil {
            armed = t <= until
            armedUntil = nil
        }

        if active {
            guard let contact = contact(m) else {
                releaseCount = 0
                let since = unreadableSince ?? t
                unreadableSince = since
                if t - since > thresholds.unreadableGrace {
                    endTouch()
                    return .ended(lifted: false)
                }
                return nil
            }
            unreadableSince = nil
            if contact.inside {
                releaseCount = 0
                apartSince = nil
                heldThroughRoll = false
                guard !Self.liftedFingers.isDisjoint(with: m.curled) else {
                    curledSince = nil
                    canMove = contact.firm
                    return nil
                }
                let since = curledSince ?? t
                curledSince = since
                if t - since > thresholds.curlGrace {
                    endTouch()
                    return .ended(lifted: false)
                }
                return nil
            }
            releaseCount += 1
            if apartSince == nil { rollingWhenApart = rolling }
            let since = apartSince ?? t
            apartSince = since
            if rolling, rollingWhenApart, t - since <= thresholds.rollHold,
               let ti = m.thumbIndex, ti <= thresholds.rollHoldApart {
                heldThroughRoll = true
                canMove = true
                return nil
            }
            if releaseCount >= thresholds.releaseFrames || heldThroughRoll {
                let lifted = !heldThroughRoll
                endTouch()
                armIfApart(m)
                return .ended(lifted: lifted)
            }
            return nil
        }

        armIfApart(m)
        let pose = armed && isPinch(m)
        if pose {
            pendingFrames = pending ? pendingFrames + 1 : 1
            pending = true
        } else if pending, pendingNoise < thresholds.confirmNoiseFrames,
                  contact(m)?.inside == true, Self.liftedFingers.isSubset(of: m.extended) {
            // A noisy frame still inside the exit threshold neither counts
            // toward the pinch nor starts the count over. More than a few
            // would let a hover that brushes the threshold now and then add
            // up to a touch.
            pendingNoise += 1
            return nil
        } else {
            pending = false
            pendingFrames = 0
        }
        if !pending { pendingNoise = 0 }
        guard pose, pendingFrames >= thresholds.confirmFrames else { return nil }
        active = true
        pending = false
        pendingFrames = 0
        pendingNoise = 0
        armed = false
        return .began
    }

    /// Whether the tips are within the exit threshold, and firmly enough to
    /// move; nil when the frame can't be read.
    private func contact(_ m: TouchMeasure) -> (inside: Bool, firm: Bool)? {
        guard m.readable, let ti = m.thumbIndex else { return nil }
        return (ti <= thresholds.pinchExit, ti <= thresholds.pinchMoveMax)
    }

    private mutating func armIfApart(_ m: TouchMeasure) {
        if m.readable, let ti = m.thumbIndex, ti > thresholds.pinchExit { armed = true }
    }

    private mutating func endTouch() {
        active = false
        releaseCount = 0
        apartSince = nil
        heldThroughRoll = false
        unreadableSince = nil
        curledSince = nil
        canMove = false
    }
}
