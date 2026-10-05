import Foundation

public enum TouchKind: String, Equatable, Sendable {
    /// Thumb and index tips touching, the other three fingers extended (an
    /// "OK" sign): one finger on the pad.
    case pinch
    /// Thumb, index and middle tips touching, ring and little extended: two
    /// fingers on the pad, to scroll.
    case threeFinger

    /// The fingers that must stay extended, off the pad. A fist or a half-closed
    /// hand never touches.
    public var liftedFingers: Set<Finger> {
        switch self {
        case .pinch: [.middle, .ring, .little]
        case .threeFinger: [.ring, .little]
        }
    }
}

/// Fingertip distance limits for a three-finger touch, per pair.
public struct ThreeFingerLimits: Equatable, Sendable {
    /// Thumb to index tip, and thumb to middle tip.
    public var thumb: Double
    /// Index to middle tip: side by side on the thumb, they stay a fingertip
    /// apart, so this is wider.
    public var indexMiddle: Double

    public init(thumb: Double, indexMiddle: Double) {
        self.thumb = thumb
        self.indexMiddle = indexMiddle
    }
}

/// Contact thresholds in hand sizes (wrist to middle knuckle).
///
/// From the user's two `--calibrate-pinch` runs on a 1080p USB webcam at 30 fps
/// (settled frames, after each step's first 1.5 s): a held thumb–index touch
/// reads 0.05–0.07 median with its 90th percentile near 0.10, while hovering a
/// hair apart reads 0.10 median at its tightest; three fingertips held together
/// read thumb–index and thumb–middle under 0.15 and index–middle 0.15–0.21.
/// Earlier recordings agree (touching 0.026 median, hovering 0.13 at the 10th
/// percentile). Entering below where hovering starts and leaving above where
/// touching ends means a near-touch never counts and a held touch never
/// flickers.
public struct TouchThresholds: Equatable, Sendable {
    /// Thumb and index tips touch below this. 0.09 already starts on the
    /// tightest hover.
    public var pinchEnter = 0.08
    /// A pinch lets go above this.
    public var pinchExit = 0.12
    /// Above this the fingers are parting, so the pointer stops and letting go
    /// can't move it.
    public var pinchMoveMax = 0.10
    /// A plain pinch needs the middle tip at least this far from the thumb and
    /// index tips. Not below `threeEnter.thumb`, so the two poses can't
    /// overlap (on the boundary itself, three-finger wins).
    public var middleApart = 0.18
    /// Thumb, index and middle tips touch when every pair is within these.
    /// Three tips can't meet at one point, so these are wider than `pinchEnter`.
    public var threeEnter = ThreeFingerLimits(thumb: 0.18, indexMiddle: 0.26)
    public var threeExit = ThreeFingerLimits(thumb: 0.22, indexMiddle: 0.32)
    public var threeMoveMax = ThreeFingerLimits(thumb: 0.20, indexMiddle: 0.29)
    /// To start, the thumb tip must also be within this of the nearer of the
    /// index and middle tips: it touches at least one. Held together, the
    /// nearer one read 0.09 median (0.115 at the 95th percentile) in
    /// calibration, while a hand closing between pinches, index and middle side
    /// by side, keeps the thumb 0.14 from both.
    public var threeThumbContact = 0.12
    /// Thumb and index tips seen with less confidence don't count.
    public var minTipConfidence = 0.4
    /// Nor does a middle tip seen with less. It's often half hidden behind
    /// the thumb in the three-finger pose (0.37 median in calibration).
    public var minMiddleTipConfidence = 0.3
    /// Nor do frames whose hand size comes from joints seen with less.
    public var minSizeConfidence = 0.3
    /// Consecutive frames a touch pose must hold before the touch begins
    /// (0.1 s at 30 fps).
    public var confirmFrames = 3
    /// Frames off the pose but still inside the exit threshold that
    /// confirmation tolerates without starting over.
    public var confirmNoiseFrames = 2
    /// A three-finger touch given up because its fingertips couldn't be read
    /// leaves the fingers armed, so the scroll resumes once they can be: the
    /// middle tip, half hidden behind the thumb, often drops out, while thumb
    /// and index stay too close to count as seen apart. (A pinch that resumed
    /// like this would click when let go after a long hold.)
    public var rearmThreeFingerAfterUnreadable = true
    /// Consecutive frames clearly apart before a touch ends.
    public var releaseFrames = 2
    /// During a touch, frames that can't be read (fingertips hidden or
    /// uncertain) hold it this long; after that it ends without a click.
    public var unreadableGrace = 0.2
    /// Fingers seen apart before the hand was lost still count if it comes
    /// back within this long, so a tracking dropout doesn't swallow a pinch.
    public var armedAfterLoss = 0.5
    /// When the fingers that must stay extended count as extended or curled.
    public var fingers = ExtensionThresholds()
    /// During a touch, one of those fingers may curl this long (the touch
    /// pauses but holds, so a drag survives a twitch); after that the touch
    /// ends without a click.
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

    /// Every pair of the three fingertips is within `limits`; nil when one
    /// distance is missing.
    public func threeWithin(_ limits: ThreeFingerLimits) -> Bool? {
        guard let a = thumbIndex, let b = thumbMiddle, let c = indexMiddle else { return nil }
        return a <= limits.thumb && b <= limits.thumb && c <= limits.indexMiddle
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
    case began(TouchKind)
    /// `lifted` is true when the fingertips were seen to part (a tap can
    /// click), false when the touch was given up because they couldn't be read.
    case ended(TouchKind, lifted: Bool)
}

/// Decides when fingertips touch.
///
/// A touch begins only after the thumb and index tips have been seen apart (the
/// frame a touch lets go counts), and then showed a touch pose on
/// `confirmFrames` frames, with at most `confirmNoiseFrames` in between that
/// stay inside the exit threshold and none that leave it or can't be read. A
/// three-finger touch given up because its tips couldn't be read may resume
/// without parting them. A touch pose includes the
/// fingers that stay off the pad (`TouchKind.liftedFingers`) being extended.
/// Once it begins, its kind is locked until it ends: a pinch can't turn into a
/// three-finger touch or back. If one of the lifted fingers curls, the touch
/// pauses; curled for longer than `curlGrace`, it ends without a click.
public struct TouchDetector: Sendable {
    public var thresholds: TouchThresholds

    /// The touch in progress.
    public private(set) var active: TouchKind?
    /// The pose being confirmed before a touch begins.
    public private(set) var pending: TouchKind?
    /// The touch is firmly in contact this frame, so it may move the pointer or scroll.
    public private(set) var canMove = false
    public private(set) var measure = TouchMeasure()
    public private(set) var fingers: FingerExtensionTracker

    private var pendingFrames = 0
    private var pendingNoise = 0
    private var releaseCount = 0
    private var unreadableSince: Double?
    private var curledSince: Double?
    private var armed = false
    private var armedUntil: Double?

    public init(thresholds: TouchThresholds = TouchThresholds()) {
        self.thresholds = thresholds
        fingers = FingerExtensionTracker(thresholds: thresholds.fingers)
    }

    /// A touch is in progress or being confirmed.
    public var isEngaged: Bool { active != nil || pending != nil }

    /// Forgets everything, including that the fingers were seen apart.
    public mutating func reset() {
        active = nil
        pending = nil
        pendingFrames = 0
        pendingNoise = 0
        releaseCount = 0
        unreadableSince = nil
        curledSince = nil
        fingers.reset()
        armed = false
        armedUntil = nil
        canMove = false
    }

    /// The hand left: any touch is over (the caller ends it), but fingers
    /// already seen apart stay so for `armedAfterLoss`.
    public mutating func handLost(at t: Double) {
        let until = armed ? t + thresholds.armedAfterLoss : armedUntil
        reset()
        armedUntil = until
    }

    /// The touch pose this frame shows, ignoring confirmation and arming.
    public func pose(_ m: TouchMeasure) -> TouchKind? {
        guard m.readable, let ti = m.thumbIndex else { return nil }
        if m.middleReadable, m.threeWithin(thresholds.threeEnter) == true,
           let tm = m.thumbMiddle, min(ti, tm) <= thresholds.threeThumbContact {
            return TouchKind.threeFinger.liftedFingers.isSubset(of: m.extended) ? .threeFinger : nil
        }
        if ti <= thresholds.pinchEnter, m.middleReadable, let gap = m.middleGap, gap >= thresholds.middleApart {
            return TouchKind.pinch.liftedFingers.isSubset(of: m.extended) ? .pinch : nil
        }
        return nil
    }

    public mutating func update(_ hand: HandSample, handSize: Double, at t: Double) -> TouchEvent? {
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

        if let kind = active {
            guard let contact = contact(kind, m) else {
                releaseCount = 0
                let since = unreadableSince ?? t
                unreadableSince = since
                if t - since > thresholds.unreadableGrace {
                    endTouch()
                    armed = kind == .threeFinger && thresholds.rearmThreeFingerAfterUnreadable
                    return .ended(kind, lifted: false)
                }
                return nil
            }
            unreadableSince = nil
            if contact.inside {
                releaseCount = 0
                guard !kind.liftedFingers.isDisjoint(with: m.curled) else {
                    curledSince = nil
                    canMove = contact.firm
                    return nil
                }
                let since = curledSince ?? t
                curledSince = since
                if t - since > thresholds.curlGrace {
                    endTouch()
                    return .ended(kind, lifted: false)
                }
                return nil
            }
            releaseCount += 1
            if releaseCount >= thresholds.releaseFrames {
                endTouch()
                armIfApart(m)
                return .ended(kind, lifted: true)
            }
            return nil
        }

        armIfApart(m)
        let kind = armed ? pose(m) : nil
        if let kind, kind == pending {
            pendingFrames += 1
        } else if kind == nil, let p = pending, pendingNoise < thresholds.confirmNoiseFrames,
                  contact(p, m)?.inside == true, p.liftedFingers.isSubset(of: m.extended) {
            // A noisy frame still inside the exit threshold neither counts
            // toward the touch nor starts the count over. More than a few
            // would let a hover that brushes the threshold now and then add
            // up to a touch.
            pendingNoise += 1
            return nil
        } else {
            pending = kind
            pendingFrames = kind == nil ? 0 : 1
            pendingNoise = 0
        }
        guard let kind, pendingFrames >= thresholds.confirmFrames else { return nil }
        active = kind
        pending = nil
        pendingFrames = 0
        pendingNoise = 0
        armed = false
        return .began(kind)
    }

    /// Whether fingertips are within a touch of `kind`'s exit threshold, and
    /// firmly enough to move; nil when the frame can't be read.
    private func contact(_ kind: TouchKind, _ m: TouchMeasure) -> (inside: Bool, firm: Bool)? {
        switch kind {
        case .pinch:
            guard m.readable, let ti = m.thumbIndex else { return nil }
            return (ti <= thresholds.pinchExit, ti <= thresholds.pinchMoveMax)
        case .threeFinger:
            guard m.middleReadable, let inside = m.threeWithin(thresholds.threeExit) else { return nil }
            return (inside, m.threeWithin(thresholds.threeMoveMax) == true)
        }
    }

    private mutating func armIfApart(_ m: TouchMeasure) {
        if m.readable, let ti = m.thumbIndex, ti > thresholds.pinchExit { armed = true }
    }

    private mutating func endTouch() {
        active = nil
        releaseCount = 0
        unreadableSince = nil
        curledSince = nil
        canMove = false
    }
}
