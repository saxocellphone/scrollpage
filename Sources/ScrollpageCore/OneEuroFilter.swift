import Foundation

/// One Euro filter (Casiez, Roussel, Vogel — CHI 2012) for a 2D signal.
///
/// Low cutoff when the hand is slow (kills jitter), higher cutoff as speed rises
/// (kills lag). The cutoff is driven by the speed magnitude so diagonal motion is
/// filtered the same as horizontal or vertical motion.
public struct OneEuroFilter2D: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var derivativeCutoff: Double

    private var value: Vec2?
    private var derivative = Vec2.zero
    private var lastTime: Double?

    public init(minCutoff: Double = 1.0, beta: Double = 1.0, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    public var current: Vec2? { value }

    public mutating func reset() {
        value = nil
        derivative = .zero
        lastTime = nil
    }

    public mutating func filter(_ x: Vec2, at t: Double) -> Vec2 {
        guard let previous = value, let last = lastTime else {
            value = x
            lastTime = t
            return x
        }
        let dt = t - last
        guard dt > 0 else { return previous }
        lastTime = t

        let rawDerivative = (x - previous) / dt
        let aD = Self.alpha(dt: dt, cutoff: derivativeCutoff)
        derivative = derivative + (rawDerivative - derivative) * aD

        let cutoff = minCutoff + beta * derivative.length
        let a = Self.alpha(dt: dt, cutoff: cutoff)
        let next = previous + (x - previous) * a
        value = next
        return next
    }

    static func alpha(dt: Double, cutoff: Double) -> Double {
        let tau = 1.0 / (2 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }
}
