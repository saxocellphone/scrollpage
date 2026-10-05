import Foundation

public enum TouchKind: String, Equatable, Sendable {
    /// Thumb and index tips touching, middle finger apart: one finger on the pad.
    case pinch
    /// Thumb, index and middle tips touching: two fingers on the pad, to scroll.
    case threeFinger
}

/// Contact thresholds in hand sizes (wrist to middle knuckle).
///
/// Measured on a 1080p USB webcam at 30 fps (four recordings, 875 hand frames):
/// fingertips that touch read 0.026 median and 0.042 at the 98th percentile
/// while a pinch is held, fingertips hovering just apart 0.13 at the 10th
/// percentile and 0.19 median, with almost nothing in between. Entering below
/// the touching cluster's ceiling and leaving inside the empty gap means a
/// near-touch never counts and a held touch never flickers.
public struct TouchThresholds: Equatable, Sendable {
    /// Thumb and index tips touch below this.
    public var pinchEnter = 0.06
    /// A pinch lets go above this.
    public var pinchExit = 0.10
    /// Above this the fingers are parting, so the pointer stops and letting go
    /// can't move it.
    public var pinchMoveMax = 0.08
    /// A plain pinch needs the middle tip at least this far from the thumb and
    /// index tips. 93 % of touching frames in the recordings clear it.
    public var middleApart = 0.22
    /// Thumb, index and middle tips all within this of each other touch. Three
    /// tips can't meet at one point, so this is wider than `pinchEnter`; in
    /// ordinary use no three consecutive frames came this close. Between it and
    /// `middleApart` neither touch can start.
    public var threeEnter = 0.12
    public var threeExit = 0.16
    public var threeMoveMax = 0.14
    /// Fingertips seen with less confidence don't count.
    public var minTipConfidence = 0.5
    /// Nor do frames whose hand size comes from joints seen with less.
    public var minSizeConfidence = 0.3
    /// Consecutive frames a touch pose must hold before the touch begins
    /// (0.1 s at 30 fps).
    public var confirmFrames = 3
    /// Consecutive frames clearly apart before a touch ends.
    public var releaseFrames = 2
    /// During a touch, frames that can't be read (fingertips hidden or
    /// uncertain) hold it this long; after that it ends without a click.
    public var unreadableGrace = 0.2
    /// Fingers seen apart before the hand was lost still count if it comes
    /// back within this long, so a tracking dropout doesn't swallow a pinch.
    public var armedAfterLoss = 0.5

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

    public init(thumbIndex: Double? = nil, thumbMiddle: Double? = nil, indexMiddle: Double? = nil,
                readable: Bool = false, middleReadable: Bool = false) {
        self.thumbIndex = thumbIndex
        self.thumbMiddle = thumbMiddle
        self.indexMiddle = indexMiddle
        self.readable = readable
        self.middleReadable = middleReadable
    }

    /// The largest of the three fingertip distances.
    public var threeSpread: Double? {
        guard let a = thumbIndex, let b = thumbMiddle, let c = indexMiddle else { return nil }
        return max(a, b, c)
    }

    /// The middle tip's distance to the nearer of the thumb and index tips.
    public var middleGap: Double? {
        guard let b = thumbMiddle, let c = indexMiddle else { return nil }
        return min(b, c)
    }

    public init(_ hand: HandSample, handSize size: Double, thresholds: TouchThresholds = TouchThresholds()) {
        func confident(_ j: HandJoint) -> Bool { (hand[j]?.confidence ?? 0) >= thresholds.minTipConfidence }
        thumbIndex = hand.ratio(.thumbTip, .indexTip, handSize: size)
        thumbMiddle = hand.ratio(.thumbTip, .middleTip, handSize: size)
        indexMiddle = hand.ratio(.indexTip, .middleTip, handSize: size)
        readable = thumbIndex != nil && confident(.thumbTip) && confident(.indexTip)
            && (hand.handSizeConfidence ?? 0) >= thresholds.minSizeConfidence
        middleReadable = readable && thumbMiddle != nil && confident(.middleTip)
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
/// A touch begins only after the thumb and index tips have been seen apart, and
/// then showed a touch pose on `confirmFrames` frames without leaving the exit
/// threshold or becoming unreadable in between. Once it
/// begins, its kind is locked until it ends: a pinch can't turn into a
/// three-finger touch or back.
public struct TouchDetector: Sendable {
    public var thresholds: TouchThresholds

    /// The touch in progress.
    public private(set) var active: TouchKind?
    /// The pose being confirmed before a touch begins.
    public private(set) var pending: TouchKind?
    /// The touch is firmly in contact this frame, so it may move the pointer or scroll.
    public private(set) var canMove = false
    public private(set) var measure = TouchMeasure()

    private var pendingFrames = 0
    private var releaseCount = 0
    private var unreadableSince: Double?
    private var armed = false
    private var armedUntil: Double?

    public init(thresholds: TouchThresholds = TouchThresholds()) {
        self.thresholds = thresholds
    }

    /// A touch is in progress or being confirmed.
    public var isEngaged: Bool { active != nil || pending != nil }

    /// Forgets everything, including that the fingers were seen apart.
    public mutating func reset() {
        active = nil
        pending = nil
        pendingFrames = 0
        releaseCount = 0
        unreadableSince = nil
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
        if m.middleReadable, let spread = m.threeSpread, spread <= thresholds.threeEnter {
            return .threeFinger
        }
        if ti <= thresholds.pinchEnter, m.middleReadable, let gap = m.middleGap, gap >= thresholds.middleApart {
            return .pinch
        }
        return nil
    }

    public mutating func update(_ hand: HandSample, handSize: Double, at t: Double) -> TouchEvent? {
        let m = TouchMeasure(hand, handSize: handSize, thresholds: thresholds)
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
                    return .ended(kind, lifted: false)
                }
                return nil
            }
            unreadableSince = nil
            if contact.inside {
                releaseCount = 0
                canMove = contact.firm
                return nil
            }
            releaseCount += 1
            if releaseCount >= thresholds.releaseFrames {
                endTouch()
                return .ended(kind, lifted: true)
            }
            return nil
        }

        if m.readable, let ti = m.thumbIndex, ti > thresholds.pinchExit { armed = true }
        let kind = armed ? pose(m) : nil
        if let kind, kind == pending {
            pendingFrames += 1
        } else if kind == nil, let p = pending, contact(p, m)?.inside == true {
            // A noisy frame still inside the exit threshold neither counts
            // toward the touch nor starts the count over.
            return nil
        } else {
            pending = kind
            pendingFrames = kind == nil ? 0 : 1
        }
        guard let kind, pendingFrames >= thresholds.confirmFrames else { return nil }
        active = kind
        pending = nil
        pendingFrames = 0
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
            guard m.middleReadable, let spread = m.threeSpread else { return nil }
            return (spread <= thresholds.threeExit, spread <= thresholds.threeMoveMax)
        }
    }

    private mutating func endTouch() {
        active = nil
        releaseCount = 0
        unreadableSince = nil
        canMove = false
    }
}
