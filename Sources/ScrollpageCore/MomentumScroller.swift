import Foundation

/// Kinetic scrolling: velocity decays as v(t) = v0 · e^(−t/τ).
///
/// τ = 325 ms is the usual iOS/macOS-like constant (about UIScrollView's normal
/// deceleration rate of 0.998 per ms). Integration is exact per step, so the
/// total glide distance is v0 · τ regardless of the tick rate.
public struct MomentumScroller: Sendable {
    public var timeConstant: Double
    /// Stop gliding below this speed (points per second).
    public var stopSpeed: Double
    public var maxSpeed: Double

    public private(set) var velocity = Vec2.zero

    public init(timeConstant: Double = 0.325, stopSpeed: Double = 30, maxSpeed: Double = 16_000) {
        self.timeConstant = timeConstant
        self.stopSpeed = stopSpeed
        self.maxSpeed = maxSpeed
    }

    public var isActive: Bool { velocity.length >= stopSpeed }

    /// Starts a glide. A fling in the same direction as a glide still under way
    /// adds to it, like repeated two-finger flings on a trackpad; any other fling
    /// replaces it.
    public mutating func fling(_ v: Vec2) {
        var next = v
        if isActive && velocity.dot(v) > 0 {
            next = velocity + v
        }
        let speed = next.length
        if speed > maxSpeed { next = next * (maxSpeed / speed) }
        velocity = next
    }

    public mutating func stop() {
        velocity = .zero
    }

    /// Advances by `dt` seconds and returns the distance travelled (points).
    public mutating func step(_ dt: Double) -> Vec2 {
        guard isActive, dt > 0 else {
            velocity = .zero
            return .zero
        }
        let decay = exp(-dt / timeConstant)
        let distance = velocity * (timeConstant * (1 - decay))
        velocity = velocity * decay
        if !isActive { velocity = .zero }
        return distance
    }
}
