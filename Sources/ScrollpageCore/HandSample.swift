import Foundation

public enum HandJoint: Int, CaseIterable, Sendable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

public struct JointPoint: Equatable, Sendable {
    public var location: Vec2
    public var confidence: Double

    public init(_ location: Vec2, confidence: Double = 1) {
        self.location = location
        self.confidence = confidence
    }
}

/// Which of the user's physical hands this is.
public enum Chirality: String, Equatable, Sendable {
    case left, right

    public var flipped: Chirality { self == .left ? .right : .left }

    /// Vision labels a hand as it appears in the image it was given. A mirrored
    /// image shows a right hand as a left one, so the label flips back.
    public static func physical(visionLabel: Chirality?, imageMirrored: Bool) -> Chirality? {
        guard let visionLabel else { return nil }
        return imageMirrored ? visionLabel.flipped : visionLabel
    }
}

/// One detected hand.
///
/// Coordinates are mirrored (so +x is the user's right, like looking in a mirror)
/// and y-down (like screen space), in units of the image *height*: y spans 0...1
/// and x spans 0...aspectRatio. Using one unit on both axes keeps distances honest.
public struct HandSample: Equatable, Sendable {
    public static let minConfidence = 0.3

    private var points: [JointPoint?]
    /// The physical hand, or nil when Vision couldn't tell.
    public var chirality: Chirality?

    public init(_ joints: [HandJoint: JointPoint], chirality: Chirality? = nil) {
        points = Array(repeating: nil, count: HandJoint.allCases.count)
        for (joint, point) in joints { points[joint.rawValue] = point }
        self.chirality = chirality
    }

    public subscript(_ joint: HandJoint) -> JointPoint? {
        get { points[joint.rawValue] }
        set { points[joint.rawValue] = newValue }
    }

    public func location(_ joint: HandJoint, minConfidence: Double = HandSample.minConfidence) -> Vec2? {
        guard let p = points[joint.rawValue], p.confidence >= minConfidence else { return nil }
        return p.location
    }

    public var allLocations: [(HandJoint, JointPoint)] {
        HandJoint.allCases.compactMap { j in points[j.rawValue].map { (j, $0) } }
    }

    /// Wrist to middle-finger knuckle: a scale reference that stays put while the
    /// fingers move, so motion can be measured in "hand units" regardless of how
    /// far the user sits from the camera.
    public var handSize: Double? { handSizeMeasure?.size }

    /// The lower confidence of the two joints `handSize` was measured from.
    public var handSizeConfidence: Double? { handSizeMeasure?.confidence }

    private var handSizeMeasure: (size: Double, confidence: Double)? {
        for (a, b, scale) in [(HandJoint.wrist, HandJoint.middleMCP, 1.0), (.indexMCP, .littleMCP, 1.45)] {
            if let pa = self[a], let pb = self[b], let la = location(a), let lb = location(b) {
                let d = la.distance(to: lb)
                if d > 1e-4 { return (d * scale, min(pa.confidence, pb.confidence)) }
            }
        }
        return nil
    }

    /// Distance between two joints over hand size, or nil if either joint is
    /// missing or below `minConfidence`.
    public func ratio(_ a: HandJoint, _ b: HandJoint, handSize size: Double? = nil,
                      minConfidence: Double = 0.2) -> Double? {
        guard let s = size ?? handSize, s > 0,
              let pa = location(a, minConfidence: minConfidence),
              let pb = location(b, minConfidence: minConfidence) else { return nil }
        return pa.distance(to: pb) / s
    }

    /// Mean of the four knuckles. It barely moves when the thumb and index tip
    /// close or open, which makes it the right point to drive the pointer during
    /// a pinch (the approach Gstrl uses).
    public var palmCenter: Vec2? {
        let knuckles: [HandJoint] = [.indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let found = knuckles.compactMap { location($0) }
        guard found.count >= 2 else { return nil }
        return found.reduce(Vec2.zero, +) / Double(found.count)
    }

    /// Thumb tip to index tip, divided by hand size.
    public func pinchRatio(handSize size: Double? = nil) -> Double? {
        ratio(.thumbTip, .indexTip, handSize: size)
    }

    /// A finger counts as extended when its tip is clearly farther from the wrist
    /// than its middle joint. This works for any hand orientation.
    public func isExtended(tip: HandJoint, pip: HandJoint) -> Bool? {
        guard let w = location(.wrist), let t = location(tip), let p = location(pip) else { return nil }
        return w.distance(to: t) > w.distance(to: p) * 1.12
    }

    public var extendedFingerCount: Int {
        let fingers: [(HandJoint, HandJoint)] = [
            (.indexTip, .indexPIP), (.middleTip, .middlePIP),
            (.ringTip, .ringPIP), (.littleTip, .littlePIP),
        ]
        return fingers.reduce(0) { $0 + ((isExtended(tip: $1.0, pip: $1.1) ?? false) ? 1 : 0) }
    }

    public var isOpenHand: Bool { extendedFingerCount >= 3 }
}

public struct HandSelectorConfig: Equatable, Sendable {
    /// A hand must be labelled right on this many frames in a row before it drives anything.
    public var acquireFrames = 3
    /// During a gesture, the followed hand may be labelled left (or unknown) this
    /// long, as Vision's label flickers, before the gesture is given up.
    public var flipGrace = 0.4
    /// Farthest a right-labelled palm may move between frames (image heights)
    /// and still be the same hand. A fast flick moves about 0.1.
    public var maxJump = 0.25
    /// Farthest, in hand sizes, a palm with any other label may move and still
    /// be taken for the followed hand, so a left hand nearby isn't.
    public var maxFlippedJump = 1.0
    /// Frames without the followed hand (motion blur) keep following it this
    /// long, so it resumes at once instead of being acquired again. A right
    /// hand seen elsewhere meanwhile is acquired straight away: tracking jumped.
    public var lostGrace = 0.2

    public init() {}
}

/// Picks the user's right hand among the detected hands; the left hand never
/// drives anything, even alone in the frame.
///
/// While a gesture is under way (`locked`), the followed hand is tracked by
/// palm position, so a brief flip of Vision's label doesn't drop a pinch. A
/// flip lasting longer than `flipGrace` drops the hand, which ends the gesture
/// as if the hand had left the frame.
public struct HandSelector: Sendable {
    public var config: HandSelectorConfig

    private var followed: (palm: Vec2, lastRight: Double, lastSeen: Double)?
    private var candidate: (palm: Vec2, frames: Int)?
    /// The hand the last `select` returned was just acquired rather than
    /// followed from an earlier frame, so it may be anywhere: whatever tracked
    /// the old hand's motion should start over.
    public private(set) var isNewHand = false

    public init(config: HandSelectorConfig = HandSelectorConfig()) {
        self.config = config
    }

    public mutating func reset() {
        followed = nil
        candidate = nil
    }

    public mutating func select(_ hands: [HandSample], at t: Double, locked: Bool) -> HandSample? {
        isNewHand = false
        let usable = hands.filter { $0.palmCenter != nil && $0.handSize != nil }

        if let f = followed {
            followed = nil
            let hand = nearest(usable, to: f.palm)
            let jump = hand.map { $0.palmCenter!.distance(to: f.palm) } ?? .infinity
            if let hand, hand.chirality == .right, jump < config.maxJump {
                followed = (hand.palmCenter!, t, t)
                return hand
            }
            if let hand, jump < config.maxFlippedJump * hand.handSize! {
                // The same hand with its label flipped: follow it through the
                // grace, but only a gesture already under way may use it.
                if t - f.lastRight <= config.flipGrace {
                    followed = (hand.palmCenter!, f.lastRight, t)
                    return locked ? hand : nil
                }
            } else if t - f.lastSeen <= config.lostGrace, !usable.contains(where: { $0.chirality == .right }) {
                followed = f
                return nil
            }
        }

        let rights = usable.filter { $0.chirality == .right }
        let pick = candidate.flatMap { c in
            nearest(rights, to: c.palm).flatMap { $0.palmCenter!.distance(to: c.palm) < config.maxJump ? $0 : nil }
        } ?? rights.max { $0.handSize! < $1.handSize! }
        guard let pick, let palm = pick.palmCenter else {
            candidate = nil
            return nil
        }
        let continues = candidate.map { palm.distance(to: $0.palm) < config.maxJump } ?? false
        let frames = continues ? candidate!.frames + 1 : 1
        if frames >= config.acquireFrames {
            candidate = nil
            followed = (palm, t, t)
            isNewHand = true
            return pick
        }
        candidate = (palm, frames)
        return nil
    }

    private func nearest(_ hands: [HandSample], to p: Vec2) -> HandSample? {
        hands.min { $0.palmCenter!.distance(to: p) < $1.palmCenter!.distance(to: p) }
    }
}
