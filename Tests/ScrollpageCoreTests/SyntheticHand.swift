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
    /// Fingers fanned apart and the thumb stretched out to the side.
    var spread = false
    /// Thumb folded across the palm.
    var thumbTucked = false
    /// Fingers (named by their knuckle) curled even when the others are open.
    var folded: Set<HandJoint> = []
    /// Joints reported with too little confidence to use.
    var hidden: Set<HandJoint> = []
    /// Rotation of the whole hand about the palm, degrees, clockwise on screen.
    var tilt = 0.0

    /// The control toggle pose: five fingers spread, palm up and facing the camera.
    static var raisedPalm: HandPose {
        var pose = HandPose()
        pose.spread = true
        return pose
    }
}

/// Builds plausible 21-joint hands for a given pose, with per-joint noise.
struct SyntheticHand {
    var noise: NoiseSource
    var sigma: Double
    /// Jitter shared by every joint in a frame, as real trackers shift the whole hand.
    var commonSigma: Double

    init(seed: UInt64 = 42, sigma: Double = 0.0015, commonSigma: Double = 0) {
        noise = NoiseSource(seed: seed)
        self.sigma = sigma
        self.commonSigma = commonSigma
    }

    mutating func sample(_ pose: HandPose) -> HandSample {
        let s = pose.size
        let p = pose.palm
        var joints: [HandJoint: Vec2] = [:]

        let mcps: [(HandJoint, Double)] = [(.indexMCP, -0.3), (.middleMCP, -0.1), (.ringMCP, 0.1), (.littleMCP, 0.3)]
        for (j, dx) in mcps { joints[j] = p + Vec2(dx * s, 0) }
        joints[.wrist] = joints[.middleMCP]! + Vec2(0, s)

        let fan: [HandJoint: Double] = [.indexMCP: -12, .middleMCP: -4, .ringMCP: 4, .littleMCP: 12]
        func finger(_ mcp: HandJoint, _ pip: HandJoint, _ dip: HandJoint, _ tip: HandJoint, open: Bool) {
            let base = joints[mcp]!
            if open && !pose.folded.contains(mcp) {
                let angle = (pose.spread ? fan[mcp]! : 0) * .pi / 180
                let up = Vec2(sin(angle), -cos(angle)) * s
                joints[pip] = base + up * 0.45
                joints[dip] = base + up * 0.70
                joints[tip] = base + up * 0.90
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
        if !pinching && pose.thumbTucked {
            joints[.thumbMP] = wrist + Vec2(-0.45 * s, -0.55 * s)
            joints[.thumbIP] = wrist + Vec2(-0.30 * s, -0.80 * s)
            joints[.thumbTip] = joints[.indexMCP]! + Vec2(0.15 * s, 0.25 * s)
        } else if !pinching && pose.spread {
            joints[.thumbMP] = wrist + Vec2(-0.65 * s, -0.45 * s)
            joints[.thumbIP] = wrist + Vec2(-0.85 * s, -0.60 * s)
            joints[.thumbTip] = wrist + Vec2(-1.00 * s, -0.75 * s)
        } else {
            joints[.thumbMP] = wrist + Vec2(-0.60 * s, -0.50 * s)
            joints[.thumbIP] = wrist + Vec2(-0.75 * s, -0.70 * s)
            joints[.thumbTip] = joints[.indexTip]! + Vec2(-pose.pinchRatio * s, 0)
        }

        let angle = pose.tilt * .pi / 180
        func rotate(_ v: Vec2) -> Vec2 {
            let d = v - p
            return p + Vec2(d.x * cos(angle) - d.y * sin(angle), d.x * sin(angle) + d.y * cos(angle))
        }

        var points: [HandJoint: JointPoint] = [:]
        let shift = Vec2(noise.gaussian(commonSigma), noise.gaussian(commonSigma))
        for (j, v) in joints.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            points[j] = JointPoint(rotate(v) + shift + Vec2(noise.gaussian(sigma), noise.gaussian(sigma)),
                                   confidence: pose.hidden.contains(j) ? 0.1 : 0.9)
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
    let dt: Double
    private(set) var outputs: [(t: Double, output: GestureOutput)] = []
    /// Frames on which the raised-palm toggle fired, with the new control state.
    private(set) var toggles: [(t: Double, on: Bool)] = []
    private(set) var progress: [(t: Double, value: Double)] = []

    init(settings: MotionSettings = MotionSettings(), seed: UInt64 = 42, sigma: Double = 0.0015,
         commonSigma: Double = 0, fps: Double = 60) {
        engine = GestureEngine(settings: settings)
        hand = SyntheticHand(seed: seed, sigma: sigma, commonSigma: commonSigma)
        dt = 1 / fps
    }

    /// Noise and frame rate measured on a USB webcam (25 fps, hand ~0.12 image
    /// heights, palm jitter ~15 thousandths of a hand per frame).
    static func webcam(seed: UInt64 = 42, fps: Double = 25) -> Rig {
        let rig = Rig(seed: seed, sigma: 0.0015, commonSigma: 0.0009, fps: fps)
        rig.pose.size = 0.12
        return rig
    }

    /// Runs for `duration` seconds. `update` gets progress 0...1 and may change the pose.
    /// Frames whose index (from 1) is in `dropped` have no hand, as when motion blur loses it.
    func run(_ duration: Double, visible: Bool = true, dropped: ClosedRange<Int>? = nil,
             _ update: ((Double, inout HandPose) -> Void)? = nil) {
        let frames = max(1, Int((duration / dt).rounded()))
        for i in 1...frames {
            t += dt
            update?(Double(i) / Double(frames), &pose)
            let sample = visible && !(dropped?.contains(i) ?? false) ? hand.sample(pose) : nil
            for o in engine.process(sample, at: t) { outputs.append((t, o)) }
            let snapshot = engine.snapshot
            if snapshot.toggled { toggles.append((t, snapshot.controlOn)) }
            progress.append((t, snapshot.toggleProgress))
        }
    }

    /// The menu switch.
    func setControl(_ on: Bool) {
        for o in engine.setControl(on: on) { outputs.append((t, o)) }
    }

    func hold(_ duration: Double) { run(duration) }

    func pinch(_ on: Bool, over duration: Double = 0.05) {
        let from = pose.pinchRatio
        let to = on ? 0.1 : 0.8
        run(duration) { p, pose in pose.pinchRatio = from + (to - from) * p }
    }

    /// Minimum-jerk move of the palm by `delta` (image-height units).
    func move(by delta: Vec2, over duration: Double, dropped: ClosedRange<Int>? = nil) {
        let start = pose.palm
        run(duration, dropped: dropped) { p, pose in
            let s = p * p * p * (10 - 15 * p + 6 * p * p)
            pose.palm = start + delta * s
        }
    }

    func clearOutputs() {
        outputs.removeAll()
        toggles.removeAll()
        progress.removeAll()
    }

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
