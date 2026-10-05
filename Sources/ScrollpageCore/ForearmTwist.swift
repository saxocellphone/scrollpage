import Foundation

/// How rolling the forearm moves the pointer, or scrolls, vertically.
///
/// Measured on the user's edge-on right hand (`--calibrate-twist`, 1080p at
/// 30 fps): the palm's width (index to little knuckle) over its length (wrist
/// to the index and middle knuckles) reads 0.45 held still. Rolling the palm up
/// toward the ceiling narrows it to about 0.23 at the peak of each roll (−45 %
/// at most, −18 % median), rolling it down toward the floor widens it to about
/// 0.53 (+18 %, +6 % median). Held still it creeps by about 7 % over a few
/// seconds, with 0.005 of noise a frame.
public struct ForearmTwistConfig: Equatable, Sendable {
    /// Fraction the width ratio falls from the hand's neutral at a full roll
    /// palm up, and rises at a full roll palm down: each direction is scaled to
    /// its own range, so a full roll either way moves as far.
    public var upRange = 0.45
    public var downRange = 0.17
    /// Hand units of motion for a full roll either way. A full sideways turn
    /// at the wrist (about 15 degrees each way) moves about 0.5.
    public var gain = 0.6
    /// Weight of moving the whole hand up or down, next to the roll.
    public var translationWeight = 0.5
    /// The wrist and the index, middle and little knuckles must be at least this confident.
    public var minConfidence = 0.5
    /// One Euro smoothing of the ratio; `beta` is per unit of ratio per second.
    public var minCutoff = 0.5
    public var beta = 6.0
    /// Rolls slower than this (fractions of neutral per second) add nothing.
    /// Held still, the rate stays under 0.12 (99th percentile); rolls run 0.35
    /// and up (90th).
    public var restRate = 0.12
    /// Window over which the rate is measured.
    public var rateWindow = 0.08
    /// A roll must run one way above the rest rate this long before it moves
    /// anything: the smoothed ratio of a still hand spikes that fast for a
    /// frame or two, a roll runs one way for 0.3 to 0.6 s.
    public var confirmTime = 0.06
    /// Play (fraction of neutral) the smoothed ratio must take up before it
    /// moves anything, each time it turns around: noise that stays within it
    /// never moves the pointer.
    public var play = 0.015
    /// Once a roll is confirmed, the play is given back over this long, so a
    /// short roll palm down (6 % of neutral, median) doesn't lose a quarter of
    /// its travel to it.
    public var playReturn = 0.15
    /// Tipping the hand toward or away from the camera foreshortens the
    /// palm's length, not its width, and would read as a roll: the roll fades
    /// out as the length's change over the width's goes from `tipStart` to
    /// `tipFull`. Rolling, the length changes 0.62 times as much as the
    /// width (median, 1.56 at the 90th percentile palm down, far less palm up).
    public var tipStart = 1.0
    public var tipFull = 1.5
    /// After starting over (a new hand, a glitch, hidden knuckles), nothing
    /// counts as a roll for this long: the filter starts from one noisy frame,
    /// and settling from it would read as one.
    public var settleTime = 0.15
    /// The noise estimate only learns while the rate is under this.
    public var calmRate = 0.25
    /// A change larger than this in one frame (fraction of neutral) is a
    /// tracking glitch. Alone, the frame is dropped; if the next frame agrees,
    /// the channel starts over there without moving.
    public var maxStep = 0.15
    /// While not engaged and calm, the neutral follows the hand with this time
    /// constant: it is the roll the hand rests at between gestures.
    public var neutralTime = 4.0
    /// While engaged and still, it follows the hand's slow creep with this
    /// one, so each side's gain stays right.
    public var adaptTime = 3.0
    /// Frame-to-frame noise of the raw ratio (fraction of neutral) the rates
    /// and play above are set for: the user's camera reads 1.0 to 1.6 % with
    /// the hand still. A noisier camera, or a hand farther away, scales them
    /// all up by its measured noise over this, so its jitter still moves nothing.
    public var referenceNoise = 0.015
    /// Time constant of the noise estimate, which only learns while the hand is calm.
    public var noiseTime = 1.0

    public init() {}
}

/// Follows the forearm's roll through the palm's width ratio and turns it into
/// vertical motion: palm up toward the ceiling moves up (negative y), palm
/// down toward the floor moves down.
///
/// Each side's range is measured from the hand's neutral roll, not from the
/// roll a pinch starts at: a pinch that lands mid-roll, palm partly up, and
/// rolls back toward neutral is moving back across the palm-up range, and
/// scaling it by the far smaller palm-down one would throw the pointer. The
/// neutral is learned while the hand rests between gestures, and creeps with
/// it while a pinch holds still. Motion is the change in the smoothed ratio's
/// position against the neutral, so moving the neutral never moves anything.
public struct ForearmTwist: Sendable {
    public var config: ForearmTwistConfig
    public var engaged = false
    /// The roll's rate this frame, in fractions of neutral per second.
    public private(set) var rate = 0.0
    /// Measured noise over `referenceNoise`, at least 1: what the rates and
    /// play are scaled by.
    public var noiseScale: Double { max(1, noise / config.referenceNoise) }
    private var noise: Double
    /// The ratio has run one way faster than the rest rate for `confirmTime`,
    /// and the palm's shape changes as in a roll rather than a tip.
    public private(set) var isRolling = false
    private var rollStart: (t: Double, up: Bool, shape: Vec2)?
    /// The anchor's lag behind the ratio when the roll was confirmed.
    private var slack: Double?
    /// The roll's speed in hand units per second, zero unless rolling: what
    /// its acceleration is picked from, steady while held motion catches up.
    public private(set) var speed = 0.0
    /// Samples the noise estimate has seen: it averages them all until its
    /// time constant takes over, so it settles within a few frames.
    private var noiseSamples = 0.0
    private var filter: OneEuroFilter2D
    /// The hand's neutral width ratio.
    public private(set) var neutral: Double?
    /// The raw ratio on the last two frames, newest last.
    private var raw: [Double] = []
    /// A raw ratio too far from the last one, waiting for the next frame to confirm it.
    private var jump: Double?
    /// The ratio the play is measured from.
    private var anchor: Double?
    private var lastTime: Double?
    /// When the channel last started over.
    private var started: Double?
    private var history: [(t: Double, r: Double, shape: Vec2)] = []
    /// Smooths the log of the palm's width and length, to tell a roll from a tip.
    private var shapeFilter: OneEuroFilter2D

    public init(config: ForearmTwistConfig = ForearmTwistConfig()) {
        self.config = config
        noise = config.referenceNoise
        filter = OneEuroFilter2D(minCutoff: config.minCutoff, beta: config.beta)
        shapeFilter = filter
    }

    public mutating func reset() {
        neutral = nil
        engaged = false
        restart()
    }

    /// The palm's width over its length, or nil when its joints can't be seen.
    public static func widthRatio(_ hand: HandSample, minConfidence c: Double) -> Double? {
        palm(hand, minConfidence: c).map { $0.width / $0.length }
    }

    /// The palm's width (index to little knuckle) and length (wrist to the
    /// index and middle knuckles).
    static func palm(_ hand: HandSample, minConfidence c: Double) -> (width: Double, length: Double)? {
        guard let wrist = hand.location(.wrist, minConfidence: c),
              let index = hand.location(.indexMCP, minConfidence: c),
              let middle = hand.location(.middleMCP, minConfidence: c),
              let little = hand.location(.littleMCP, minConfidence: c) else { return nil }
        let length = ((index + middle) * 0.5 - wrist).length
        let width = index.distance(to: little)
        return length > 1e-6 && width > 1e-6 ? (width, length) : nil
    }

    /// Vertical motion in hand units (y-down) this frame.
    public mutating func update(_ hand: HandSample, at t: Double) -> Double {
        guard let palm = Self.palm(hand, minConfidence: config.minConfidence) else {
            restart()
            return 0
        }
        let w = palm.width / palm.length
        if let p = raw.last, let n = neutral, abs(w - p) / n > config.maxStep {
            // A lone outlier is dropped; a jump the next frame confirms starts over there.
            guard let j = jump, abs(w - j) / n <= config.maxStep else {
                jump = w
                rate = 0
                return 0
            }
            restart()
        }
        jump = nil
        let dt = lastTime.map { max(0, t - $0) } ?? 0
        if lastTime == nil { started = t }
        lastTime = t
        let settled = t - (started ?? t) >= config.settleTime
        let scale = noiseScale
        // The filter opens with the ratio's speed, which noise inflates too.
        filter.beta = config.beta / scale
        shapeFilter.beta = config.beta / scale
        let r = filter.filter(Vec2(w, 0), at: t).x
        let shape = shapeFilter.filter(Vec2(log(palm.width), log(palm.length)), at: t)
        var n = neutral ?? r
        let restRate = config.restRate * scale
        history.append((t, r, shape))
        while history.count > 2, t - history[1].t >= config.rateWindow { history.removeFirst() }
        let step = history.first.map { r - $0.r } ?? 0
        rate = history.first.map { t > $0.t ? abs(step) / n / (t - $0.t) : 0 } ?? 0
        if settled, rate > restRate, step != 0 {
            if rollStart?.up != (step < 0) { rollStart = (t, step < 0, history[0].shape) }
        } else {
            rollStart = nil
        }
        // Over the whole roll so far, so the noise of a few frames can't let a tip through.
        let change = rollStart.map { shape - $0.shape } ?? .zero
        let weight = 1 - smoothstep(config.tipStart, config.tipFull, abs(change.y) / max(abs(change.x), 1e-9))
        let rolled = rollStart.map { t - $0.t - config.confirmTime } ?? -1
        let confirmed = rolled >= 0
        isRolling = confirmed && weight > 0.5

        // Held until the roll is confirmed, then caught up over `playReturn`
        // along with the play: a spike that turns back moves nothing, and a
        // roll loses nothing.
        let last = anchor
        var band = config.play * scale * n
        if confirmed {
            if slack == nil { slack = max(band, last.map { abs(r - $0) } ?? 0) }
            band = slack! * max(0, 1 - rolled / config.playReturn)
        } else {
            slack = nil
        }
        let a = !settled ? r : rate > restRate && !confirmed ? last ?? r : last.map { min(max($0, r - band), r + band) } ?? r
        anchor = a
        speed = confirmed ? history.first.map { t > $0.t ? abs(position(r, neutral: n) - position($0.r, neutral: n)) * config.gain / (t - $0.t) : 0 } ?? 0 : 0
        if rate < restRate {
            n += (r - n) * min(1, dt / (engaged ? config.adaptTime : config.neutralTime))
        }
        neutral = n
        if raw.count == 2, rate < config.calmRate * scale {
            // Mean absolute second difference of white noise is 1.95 sigma.
            let sample = abs(w - 2 * raw[1] + raw[0]) / n / 1.95
            noiseSamples += 1
            noise += (min(sample, 3 * noise) - noise) * max(1 / noiseSamples, min(1, dt / config.noiseTime))
        }
        raw = Array((raw + [w]).suffix(2))

        guard engaged, let last, confirmed else { return 0 }
        return (position(a, neutral: n) - position(last, neutral: n)) * config.gain * weight
    }

    /// Full rolls from neutral, negative palm up.
    private func position(_ r: Double, neutral n: Double) -> Double {
        (r - n) / n / (r < n ? config.upRange : config.downRange)
    }

    private mutating func restart() {
        raw.removeAll()
        jump = nil
        anchor = nil
        lastTime = nil
        history.removeAll()
        filter.reset()
        shapeFilter.reset()
        rate = 0
        rollStart = nil
        isRolling = false
        slack = nil
        speed = 0
    }
}
