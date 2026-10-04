import Foundation
@testable import ScrollpageCore

/// Deterministic Gaussian noise (SplitMix64 + Box–Muller).
struct NoiseSource {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func uniform() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return (Double(z >> 11) + 0.5) / Double(1 << 53)
    }

    mutating func gaussian(_ sigma: Double) -> Double {
        let u1 = uniform(), u2 = uniform()
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

struct HandPose {
    /// Mean of the four knuckles, in image-height units (y-down, mirrored).
    var palm = Vec2(0.8, 0.5)
    /// Wrist to middle knuckle, image-height units.
    var size = 0.18
    /// Thumb tip to index tip over hand size.
    var pinchRatio = 0.8
    /// Middle, ring and little fingers extended (index too unless pinching).
    var fingersOpen = true
}

/// Builds plausible 21-joint hands for a given pose, with per-joint noise.
struct SyntheticHand {
    var noise: NoiseSource
    var sigma: Double

    init(seed: UInt64 = 42, sigma: Double = 0.0015) {
        noise = NoiseSource(seed: seed)
        self.sigma = sigma
    }

    mutating func sample(_ pose: HandPose) -> HandSample {
        let s = pose.size
        let p = pose.palm
        var joints: [HandJoint: Vec2] = [:]

        let mcps: [(HandJoint, Double)] = [(.indexMCP, -0.3), (.middleMCP, -0.1), (.ringMCP, 0.1), (.littleMCP, 0.3)]
        for (j, dx) in mcps { joints[j] = p + Vec2(dx * s, 0) }
        joints[.wrist] = joints[.middleMCP]! + Vec2(0, s)

        func finger(_ mcp: HandJoint, _ pip: HandJoint, _ dip: HandJoint, _ tip: HandJoint, open: Bool) {
            let base = joints[mcp]!
            if open {
                joints[pip] = base + Vec2(0, -0.45 * s)
                joints[dip] = base + Vec2(0, -0.70 * s)
                joints[tip] = base + Vec2(0, -0.90 * s)
            } else {
                joints[pip] = base + Vec2(0, -0.35 * s)
                joints[dip] = base + Vec2(0, -0.15 * s)
                joints[tip] = base + Vec2(0, 0.10 * s)
            }
        }
        finger(.middleMCP, .middlePIP, .middleDIP, .middleTip, open: pose.fingersOpen)
        finger(.ringMCP, .ringPIP, .ringDIP, .ringTip, open: pose.fingersOpen)
        finger(.littleMCP, .littlePIP, .littleDIP, .littleTip, open: pose.fingersOpen)

        let pinching = pose.pinchRatio < 0.5
        if pinching {
            let base = joints[.indexMCP]!
            joints[.indexPIP] = base + Vec2(-0.15 * s, -0.40 * s)
            joints[.indexDIP] = base + Vec2(-0.30 * s, -0.45 * s)
            joints[.indexTip] = base + Vec2(-0.40 * s, -0.40 * s)
        } else {
            finger(.indexMCP, .indexPIP, .indexDIP, .indexTip, open: pose.fingersOpen)
        }

        let wrist = joints[.wrist]!
        joints[.thumbCMC] = wrist + Vec2(-0.35 * s, -0.25 * s)
        joints[.thumbMP] = wrist + Vec2(-0.60 * s, -0.50 * s)
        joints[.thumbIP] = wrist + Vec2(-0.75 * s, -0.70 * s)
        joints[.thumbTip] = joints[.indexTip]! + Vec2(-pose.pinchRatio * s, 0)

        var points: [HandJoint: JointPoint] = [:]
        for (j, v) in joints {
            points[j] = JointPoint(v + Vec2(noise.gaussian(sigma), noise.gaussian(sigma)), confidence: 0.9)
        }
        return HandSample(points)
    }
}

/// Drives a `GestureEngine` at a fixed frame rate and collects its outputs.
final class Rig {
    let engine: GestureEngine
    var hand: SyntheticHand
    var pose = HandPose()
    var t = 100.0
    let dt = 1.0 / 60
    private(set) var outputs: [(t: Double, output: GestureOutput)] = []

    init(settings: MotionSettings = MotionSettings(), seed: UInt64 = 42, sigma: Double = 0.0015) {
        engine = GestureEngine(settings: settings)
        hand = SyntheticHand(seed: seed, sigma: sigma)
    }

    /// Runs for `duration` seconds. `update` gets progress 0...1 and may change the pose.
    func run(_ duration: Double, visible: Bool = true, _ update: ((Double, inout HandPose) -> Void)? = nil) {
        let frames = max(1, Int((duration / dt).rounded()))
        for i in 1...frames {
            t += dt
            update?(Double(i) / Double(frames), &pose)
            let sample = visible ? hand.sample(pose) : nil
            for o in engine.process(sample, at: t) { outputs.append((t, o)) }
        }
    }

    func hold(_ duration: Double) { run(duration) }

    func pinch(_ on: Bool, over duration: Double = 0.05) {
        let from = pose.pinchRatio
        let to = on ? 0.1 : 0.8
        run(duration) { p, pose in pose.pinchRatio = from + (to - from) * p }
    }

    /// Minimum-jerk move of the palm by `delta` (image-height units).
    func move(by delta: Vec2, over duration: Double) {
        let start = pose.palm
        run(duration) { p, pose in
            let s = p * p * p * (10 - 15 * p + 6 * p * p)
            pose.palm = start + delta * s
        }
    }

    func clearOutputs() { outputs.removeAll() }

    var clicks: [Int] {
        outputs.compactMap { if case let .click(c) = $0.output { return c } else { return nil } }
    }

    var flings: [Vec2] {
        outputs.compactMap { if case let .fling(vx, vy) = $0.output { return Vec2(vx, vy) } else { return nil } }
    }

    func pointerTravel(since: Double = -.infinity) -> (net: Vec2, path: Double) {
        var net = Vec2.zero
        var path = 0.0
        for (t, o) in outputs where t >= since {
            if case let .pointerMoved(dx, dy) = o {
                net += Vec2(dx, dy)
                path += Vec2(dx, dy).length
            }
        }
        return (net, path)
    }

    func count(_ match: GestureOutput) -> Int { outputs.filter { $0.output == match }.count }
}
