import Foundation

/// When a closed fist counts, to scroll.
///
/// From the user's `--calibrate-fist` run (right hand edge-on, 1080p at
/// 30 fps): once the fist has formed, all four fingers read curled on every
/// frame, held still, rolled either way or moved up and down, and none read
/// extended. Their tips stay within 0.48–0.61 hand sizes (median) of the
/// knuckles' centre, 0.81 at most while rolling. A relaxed open hand reads all
/// four extended, tips 0.96 out; a loosely curled, half-closed hand never reads
/// all four curled (the index and little finger stay between), tips 0.80 out.
public struct FistThresholds: Equatable, Sendable {
    /// To start, every fingertip within this of the knuckles' centre (hand sizes).
    public var tipReachEnter = 0.70
    /// Beyond this the fingers are opening.
    public var tipReachExit = 0.90
    /// Fingers read extended (with the finger tracker's hysteresis) that end the fist.
    public var openFingers = 2
    /// Consecutive fist frames before scrolling starts (0.1 s at 30 fps).
    public var confirmFrames = 3
    /// Consecutive frames opening before the fist ends.
    public var releaseFrames = 2
    /// Faster palm motion (hand units per second) can't start a fist: a hand
    /// closing on the way somewhere isn't scrolling. Held still it moves 0.35
    /// (median, 0.86 at the 95th percentile).
    public var maxStartSpeed = 2.0
    /// Thumb and index tips closer than this (hand sizes) can't start a fist:
    /// that is a pinch with the other fingers curled in (0.11 median, 0.14 at
    /// the 95th percentile in the second calibration run). A still fist reads
    /// 0.24 and up. Once a fist is held this no longer applies: rolled palm
    /// down, the thumb tip lands on the index tip in the image.
    public var minThumbIndexToStart = 0.15
    /// During a fist, frames whose fingertips can't be seen hold it this long.
    public var unreadableGrace = 0.3
    /// Fingers seen open before the hand was lost still count if it comes
    /// back within this long.
    public var armedAfterLoss = 0.5
    public var fingers = ExtensionThresholds()

    public init() {}
}

public enum FistEvent: Equatable, Sendable {
    case began
    /// `opened` is true when the fingers were seen to open, false when the
    /// fist was given up because they couldn't be read.
    case ended(opened: Bool)
}

/// Decides when the hand makes a fist.
///
/// A fist begins only after `openFingers` fingers have been seen extended (so
/// a hand that arrives closed doesn't scroll, even if noise leaves a finger
/// reading in between), then all four read curled with
/// their tips close in, and the thumb off the index tip, on `confirmFrames`
/// frames in a row while the hand moves slower than `maxStartSpeed`. It ends when `openFingers` fingers read
/// extended or a tip reaches past `tipReachExit`, for `releaseFrames` frames.
public struct FistDetector: Sendable {
    public var thresholds: FistThresholds
    public private(set) var active = false
    public private(set) var fingers: FingerExtensionTracker
    /// The farthest fingertip from the knuckles' centre this frame, hand sizes.
    public private(set) var reach: Double?

    private var pendingFrames = 0
    private var releaseCount = 0
    private var unreadableSince: Double?
    private var armed = false
    private var armedUntil: Double?

    public init(thresholds: FistThresholds = FistThresholds()) {
        self.thresholds = thresholds
        fingers = FingerExtensionTracker(thresholds: thresholds.fingers)
    }

    /// A fist is held or being confirmed.
    public var isEngaged: Bool { active || pendingFrames > 0 }

    public mutating func reset() {
        active = false
        pendingFrames = 0
        releaseCount = 0
        unreadableSince = nil
        armed = false
        armedUntil = nil
        fingers.reset()
        reach = nil
    }

    public mutating func handLost(at t: Double) {
        let until = armed ? t + thresholds.armedAfterLoss : armedUntil
        reset()
        armedUntil = until
    }

    /// Farthest fingertip from the knuckles' centre over hand size, or nil
    /// when a tip can't be seen.
    public static func tipReach(_ hand: HandSample, handSize: Double, minConfidence: Double) -> Double? {
        guard handSize > 0, let palm = hand.palmCenter else { return nil }
        var farthest = 0.0
        for finger in Finger.allCases {
            guard let tip = hand.location(finger.joints.tip, minConfidence: minConfidence) else { return nil }
            farthest = max(farthest, tip.distance(to: palm) / handSize)
        }
        return farthest
    }

    /// `speed`: the palm's speed in hand units per second. `canStart`: false
    /// while another gesture is under way.
    public mutating func update(_ hand: HandSample, handSize: Double, speed: Double, canStart: Bool = true,
                                at t: Double) -> FistEvent? {
        let th = thresholds
        fingers.thresholds = th.fingers
        fingers.update(hand)
        reach = Self.tipReach(hand, handSize: handSize, minConfidence: th.fingers.minConfidence)
        if let until = armedUntil {
            armed = t <= until
            armedUntil = nil
        }
        let curled = fingers.curled.count == Finger.allCases.count
        let opening = fingers.extended.count >= th.openFingers || (reach ?? 0) > th.tipReachExit

        if active {
            if opening {
                unreadableSince = nil
                releaseCount += 1
                if releaseCount >= th.releaseFrames {
                    end()
                    armed = true
                    return .ended(opened: true)
                }
                return nil
            }
            releaseCount = 0
            if reach == nil {
                let since = unreadableSince ?? t
                unreadableSince = since
                if t - since > th.unreadableGrace {
                    end()
                    return .ended(opened: false)
                }
            } else {
                unreadableSince = nil
            }
            return nil
        }

        if fingers.extended.count >= th.openFingers && reach != nil { armed = true }
        let pinching = hand.pinchRatio(handSize: handSize).map { $0 < th.minThumbIndexToStart } ?? false
        let fist = canStart && armed && curled && (reach.map { $0 <= th.tipReachEnter } ?? false)
            && speed <= th.maxStartSpeed && !pinching
        pendingFrames = fist ? pendingFrames + 1 : 0
        guard pendingFrames >= th.confirmFrames else { return nil }
        active = true
        pendingFrames = 0
        armed = false
        return .began
    }

    private mutating func end() {
        active = false
        pendingFrames = 0
        releaseCount = 0
        unreadableSince = nil
    }
}
