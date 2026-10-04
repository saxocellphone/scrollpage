import CoreGraphics
import Foundation

/// Plain 2D vector used throughout the engine. Kept separate from CGPoint so the
/// math reads the same in tests and in the app.
public struct Vec2: Equatable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)

    public var length: Double { (x * x + y * y).squareRoot() }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }
    public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }
    public static func += (a: inout Vec2, b: Vec2) { a = a + b }

    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    public func distance(to o: Vec2) -> Double { (self - o).length }

    public var description: String { String(format: "(%.4f, %.4f)", x, y) }
}

@inline(__always)
func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

@inline(__always)
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

/// Hermite smoothstep, 0 below `edge0`, 1 above `edge1`.
@inline(__always)
func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = clamp01((x - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
}
