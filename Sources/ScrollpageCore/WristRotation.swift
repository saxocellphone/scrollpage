import Foundation

/// How turning the hand at the wrist moves the pointer.
public struct WristRotationConfig: Equatable, Sendable {
    /// Hand units of pointer motion per radian the hand turns: how far from the
    /// wrist a point on the hand would have to be to move that much. The
    /// knuckles are 1 away, so above 1 the angle moves the pointer more than the
    /// knuckles themselves move.
    public var lever = 2.0
    /// Time constant of the slow reference that wrist-to-knuckle length changes
    /// (the hand tipping toward or away from the camera) are measured against.
    public var referenceTime = 1.5
    /// A turn larger than this in one frame (radians, or a length change of
    /// this fraction) is a tracking glitch and is ignored.
    public var maxStep = 0.35
    /// The wrist and the index and middle knuckles must be at least this confident.
    public var minConfidence = 0.5
    /// Turns slower than this (radians per second, which is hand units per
    /// second at the knuckles) add nothing, fading in fully by `fullRate`: the
    /// pointer's own rest speeds, so a hand at rest that slowly sways or
    /// creeps in angle stays put just as one that creeps in position does.
    public var restRate = 0.06
    public var fullRate = 0.2
    /// Window over which the turn rate is measured.
    public var rateWindow = 0.08

    public init() {}
}

/// Follows the hand's angle from the wrist to the index and middle knuckles.
///
/// Yaw is that vector's angle in the image; pitch is its length against a slow
/// reference, which shrinks as the hand tips toward or away from the camera.
/// Both become pointer motion at `lever` hand units per radian: yaw turning
/// clockwise on screen moves the pointer right, the hand lengthening (the
/// knuckles rising away from the wrist) moves it up.
///
/// The palm already moves when the hand turns about the wrist, so the part of
/// the palm's motion the turn accounts for is taken back out: what is left is
/// the wrist's own motion. A turn about the wrist then counts once, at `lever`,
/// and moving the whole hand without turning it counts as before.
public struct WristRotation: Sendable {
    public var config: WristRotationConfig
    /// Smooths the wrist-to-knuckle vector before its angle is taken.
    public var filter = OneEuroFilter2D(minCutoff: 0.5, beta: 1)

    private var previous: (u: Vec2, angle: Double, length: Double)?
    private var reference: Double?
    private var lastTime: Double?
    private var history: [(t: Double, u: Vec2)] = []

    public init(config: WristRotationConfig = WristRotationConfig()) {
        self.config = config
    }

    public mutating func reset() {
        previous = nil
        reference = nil
        lastTime = nil
        history.removeAll()
        filter.reset()
    }

    /// Pointer motion in hand units to add to the palm's motion this frame.
    public mutating func update(_ hand: HandSample, handSize: Double, at t: Double) -> Vec2 {
        let c = config.minConfidence
        guard handSize > 0,
              let wrist = hand.location(.wrist, minConfidence: c),
              let index = hand.location(.indexMCP, minConfidence: c),
              let middle = hand.location(.middleMCP, minConfidence: c) else {
            lose()
            return .zero
        }
        let v = (index + middle) * 0.5 - wrist
        guard v.length > 1e-6 else {
            lose()
            return .zero
        }
        let dt = lastTime.map { max(0, t - $0) } ?? 0
        lastTime = t
        let ref = reference.map { $0 + (v.length - $0) * min(1, dt / config.referenceTime) } ?? v.length
        reference = ref
        // In units of the reference length, so the vector's length is the pitch.
        let u = filter.filter(v / ref, at: t)
        let angle = atan2(u.x, -u.y)
        let length = u.length
        history.append((t, u))
        while history.count > 2, t - history[1].t >= config.rateWindow { history.removeFirst() }
        defer { previous = (u, angle, length) }
        guard let p = previous, let first = history.first, t > first.t else { return .zero }

        let yaw = remainder(angle - p.angle, 2 * .pi)
        let pitch = length - p.length
        guard abs(yaw) <= config.maxStep, abs(pitch) <= config.maxStep else { return .zero }
        let rate = u.distance(to: first.u) / (t - first.t)
        guard rate > config.restRate else { return .zero }
        let weight = smoothstep(config.restRate, config.fullRate, rate)
        return (Vec2(yaw, -pitch) * config.lever - (u - p.u) * (ref / handSize)) * weight
    }

    /// The knuckles or wrist can't be seen: start over when they can.
    private mutating func lose() {
        previous = nil
        history.removeAll()
        filter.reset()
    }
}
