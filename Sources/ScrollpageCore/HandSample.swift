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

/// One detected hand.
///
/// Coordinates are mirrored (so +x is the user's right, like looking in a mirror)
/// and y-down (like screen space), in units of the image *height*: y spans 0...1
/// and x spans 0...aspectRatio. Using one unit on both axes keeps distances honest.
public struct HandSample: Equatable, Sendable {
    public static let minConfidence = 0.3

    private var points: [JointPoint?]

    public init(_ joints: [HandJoint: JointPoint]) {
        points = Array(repeating: nil, count: HandJoint.allCases.count)
        for (joint, point) in joints { points[joint.rawValue] = point }
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
    public var handSize: Double? {
        if let w = location(.wrist), let m = location(.middleMCP) {
            let d = w.distance(to: m)
            if d > 1e-4 { return d }
        }
        if let i = location(.indexMCP), let l = location(.littleMCP) {
            let d = i.distance(to: l)
            if d > 1e-4 { return d * 1.45 }
        }
        return nil
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
        guard let s = size ?? handSize, s > 0,
              let thumb = location(.thumbTip, minConfidence: 0.2),
              let index = location(.indexTip, minConfidence: 0.2) else { return nil }
        return thumb.distance(to: index) / s
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

public enum HandSelector {
    /// Picks the hand to follow: the one closest to the hand we were already
    /// following, otherwise the largest (nearest to the camera).
    public static func select(_ hands: [HandSample], previousPalm: Vec2?) -> HandSample? {
        let usable = hands.filter { $0.palmCenter != nil && $0.handSize != nil }
        if let prev = previousPalm,
           let nearest = usable.min(by: { $0.palmCenter!.distance(to: prev) < $1.palmCenter!.distance(to: prev) }),
           nearest.palmCenter!.distance(to: prev) < 0.25 {
            return nearest
        }
        return usable.max(by: { $0.handSize! < $1.handSize! })
    }
}
