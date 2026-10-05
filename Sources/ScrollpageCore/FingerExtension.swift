import Foundation

public enum Finger: Int, CaseIterable, Sendable {
    case index, middle, ring, little

    /// Knuckle, middle joint, end joint and tip.
    public var joints: (mcp: HandJoint, pip: HandJoint, dip: HandJoint, tip: HandJoint) {
        switch self {
        case .index: (.indexMCP, .indexPIP, .indexDIP, .indexTip)
        case .middle: (.middleMCP, .middlePIP, .middleDIP, .middleTip)
        case .ring: (.ringMCP, .ringPIP, .ringDIP, .ringTip)
        case .little: (.littleMCP, .littlePIP, .littleDIP, .littleTip)
        }
    }
}

/// When a finger counts as extended or curled.
///
/// The main measure is how much farther the tip is from the wrist than the
/// middle joint: rotating the hand in the image doesn't change it, and it needs
/// no hand size. Measured on a 1080p USB webcam (five recordings, about 850
/// frames per finger), it is bimodal: curled fingers read 0.60 to 0.80, extended
/// ones 0.95 to 1.40, with 20 to 30 frames per finger in between. While the
/// thumb and index touched, the other three fingers read 1.06 or more (5th
/// percentile of the little finger; middle 1.14, ring 1.09), so a relaxed but
/// extended hand clears the engage tolerance easily.
///
/// When the hand is foreshortened or the wrist is hidden, the angle at the
/// middle joint decides instead: curled fingers bend it to 105 to 110 degrees
/// (90th percentile), extended ones keep it above 124 to 128 (10th percentile).
public struct ExtensionThresholds: Equatable, Sendable {
    /// Tip-to-wrist over middle-joint-to-wrist at or above this is extended.
    public var engageRatio = 0.92
    /// Below this (and not straight at the middle joint) is curled.
    public var releaseRatio = 0.85
    /// Below this the ratio alone says curled, whatever the angle.
    public var ratioFloor = 0.80
    /// Middle-joint angle in degrees (180 is straight) at or above this is
    /// extended when the ratio is unknown or between `ratioFloor` and `engageRatio`.
    public var engageAngle = 120.0
    /// Below this angle (or with no angle) a low ratio is curled.
    public var releaseAngle = 112.0
    public var minConfidence = 0.3
    /// Consecutive frames a finger must read the other way before its state flips.
    public var confirmFrames = 2

    public init() {}
}

public enum FingerReading: Equatable, Sendable {
    case extended, curled
    /// Between the engage and release tolerances: the state doesn't change.
    case between
    case unreadable
}

extension HandSample {
    /// Tip-to-wrist distance over middle-joint-to-wrist distance.
    public func extensionRatio(_ finger: Finger, minConfidence: Double = HandSample.minConfidence) -> Double? {
        let j = finger.joints
        guard let w = location(.wrist, minConfidence: minConfidence),
              let pip = location(j.pip, minConfidence: minConfidence),
              let tip = location(j.tip, minConfidence: minConfidence) else { return nil }
        let base = w.distance(to: pip)
        return base > 1e-6 ? w.distance(to: tip) / base : nil
    }

    /// Angle at the middle joint in degrees, 180 when the finger is straight.
    public func middleJointAngle(_ finger: Finger, minConfidence: Double = HandSample.minConfidence) -> Double? {
        let j = finger.joints
        guard let mcp = location(j.mcp, minConfidence: minConfidence),
              let pip = location(j.pip, minConfidence: minConfidence),
              let dip = location(j.dip, minConfidence: minConfidence) else { return nil }
        let a = mcp - pip, b = dip - pip
        let n = a.length * b.length
        guard n > 1e-12 else { return nil }
        return acos(max(-1, min(1, a.dot(b) / n))) * 180 / .pi
    }

    public func extensionReading(_ finger: Finger, thresholds th: ExtensionThresholds = ExtensionThresholds()) -> FingerReading {
        let ratio = extensionRatio(finger, minConfidence: th.minConfidence)
        let angle = middleJointAngle(finger, minConfidence: th.minConfidence)
        if ratio == nil && angle == nil { return .unreadable }
        if let ratio, ratio >= th.engageRatio { return .extended }
        if let angle, angle >= th.engageAngle, ratio.map({ $0 >= th.ratioFloor }) ?? true { return .extended }
        if ratio.map({ $0 < th.releaseRatio }) ?? true, angle.map({ $0 < th.releaseAngle }) ?? true { return .curled }
        return .between
    }
}

/// Each finger's extended or curled state, with hysteresis: readings between
/// the tolerances, or unreadable, keep the state, and a flip needs
/// `confirmFrames` readings in a row. A finger not read before takes its first
/// clear reading at once.
public struct FingerExtensionTracker: Equatable, Sendable {
    public var thresholds: ExtensionThresholds

    /// nil until the finger has been read.
    private var states: [Bool?] = Array(repeating: nil, count: Finger.allCases.count)
    private var streaks = Array(repeating: 0, count: Finger.allCases.count)

    public init(thresholds: ExtensionThresholds = ExtensionThresholds()) {
        self.thresholds = thresholds
    }

    public mutating func reset() {
        states = Array(repeating: nil, count: Finger.allCases.count)
        streaks = Array(repeating: 0, count: Finger.allCases.count)
    }

    public mutating func update(_ hand: HandSample) {
        for finger in Finger.allCases {
            let i = finger.rawValue
            let reading: Bool?
            switch hand.extensionReading(finger, thresholds: thresholds) {
            case .extended: reading = true
            case .curled: reading = false
            case .between, .unreadable: reading = nil
            }
            guard let reading, reading != states[i] else {
                streaks[i] = 0
                continue
            }
            streaks[i] += 1
            if states[i] == nil || streaks[i] >= thresholds.confirmFrames {
                states[i] = reading
                streaks[i] = 0
            }
        }
    }

    public func isExtended(_ finger: Finger) -> Bool { states[finger.rawValue] == true }
    public func isCurled(_ finger: Finger) -> Bool { states[finger.rawValue] == false }

    public var extended: Set<Finger> { Set(Finger.allCases.filter(isExtended)) }
    public var curled: Set<Finger> { Set(Finger.allCases.filter(isCurled)) }
}
