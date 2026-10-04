import Foundation

/// macOS-style pointer acceleration: the gain (screen points per hand unit of
/// motion) depends on how fast the hand moves.
///
/// - Below `restSpeed` the gain fades to zero, which is what keeps a still hand
///   from drifting the pointer.
/// - Around `slowSpeed` the gain is `slowGain`: small, precise movements.
/// - Above `fastSpeed` the gain is `fastGain`: one quick sweep crosses the screen.
/// - In between the gain rises smoothly in log-speed, the same shape as the
///   macOS curves (speed perception is roughly logarithmic).
///
/// Output speed (`speed * gain`) is monotonic in input speed, so moving faster
/// never moves the pointer less.
public struct PointerAcceleration: Equatable, Sendable {
    public var slowGain: Double
    public var fastGain: Double
    public var slowSpeed: Double
    public var fastSpeed: Double
    public var restSpeed: Double
    public var restBlendSpeed: Double

    public init(slowGain: Double, fastGain: Double, slowSpeed: Double = 0.35, fastSpeed: Double = 5.0,
                restSpeed: Double = 0.06, restBlendSpeed: Double = 0.2) {
        self.slowGain = slowGain
        self.fastGain = fastGain
        self.slowSpeed = slowSpeed
        self.fastSpeed = fastSpeed
        self.restSpeed = restSpeed
        self.restBlendSpeed = restBlendSpeed
    }

    /// `trackingSpeed` is the 0...1 slider. Like the macOS slider it mostly changes
    /// how far fast movements go, and only gently changes precise movements.
    /// `screenWidth` is in points; a fast sweep of about one hand unit covers it.
    public init(trackingSpeed: Double, screenWidth: Double) {
        let s = clamp01(trackingSpeed)
        self.init(slowGain: 165 * lerp(0.7, 1.4, s),
                  fastGain: max(600, screenWidth) * lerp(0.6, 1.7, s))
    }

    public func gain(forSpeed speed: Double) -> Double {
        guard speed > restSpeed else { return 0 }
        let rest = smoothstep(restSpeed, restBlendSpeed, speed)
        let t = smoothstep(log(slowSpeed), log(fastSpeed), log(speed))
        return rest * lerp(slowGain, fastGain, t)
    }

    /// Converts a hand displacement (hand units) into a pointer displacement
    /// (points), given the current hand speed (hand units per second).
    public func displacement(for handDelta: Vec2, speed: Double) -> Vec2 {
        handDelta * gain(forSpeed: speed)
    }
}
