import Foundation

public enum FlickAxis: Equatable, Sendable { case vertical, horizontal }

public struct Flick: Equatable, Sendable {
    public var axis: FlickAxis
    /// +1 for right/down, -1 for left/up, in the hand's (mirrored, y-down) frame.
    public var sign: Double
    /// Peak hand speed during the stroke, in hand units per second.
    public var peakSpeed: Double
    /// Stroke length along its axis, in hand units.
    public var distance: Double
    public var time: Double

    public var direction: Vec2 {
        axis == .vertical ? Vec2(0, sign) : Vec2(sign, 0)
    }
}

/// How a stroke was judged, for diagnostics.
public enum FlickVerdict: String, Sendable {
    case flick
    case tooBrief = "too brief"
    case tooSlow = "too slow"
    case offAxis = "off axis"
    case tooShort = "too short"
    case returnStroke = "return stroke"
    case sweep = "sweep (too long)"
}

public struct StrokeReport: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var peakSpeed: Double
    /// Displacement over the stroke, in hand units.
    public var displacement: Vec2
    public var verdict: FlickVerdict

    public var summary: String {
        String(format: "stroke %@: %.0f ms, peak %.2f hu/s, moved (%.2f, %.2f) hu",
               verdict.rawValue, (end - start) * 1000, peakSpeed, displacement.x, displacement.y)
    }
}

public struct FlickConfig: Equatable, Sendable {
    /// Speed (hand units/s) that opens a candidate stroke.
    public var startSpeed = 1.5
    /// A stroke must peak at least this fast to count as a flick.
    public var minPeakSpeed = 3.5
    /// The stroke ends once speed falls below this fraction of its peak.
    public var endFraction = 0.45
    public var minDistance = 0.35
    public var minDuration = 0.03
    /// Longer sustained motion is a sweep, not a flick, and is ignored.
    public var maxDuration = 0.3
    /// A stroke peaking at least this fast may last up to `maxFastDuration`: a
    /// vigorous flick often starts with a slow lead-in that counts towards its
    /// length, while repositioning sweeps stay well below this speed.
    public var fastPeakSpeed = 8.0
    public var maxFastDuration = 0.45
    /// The dominant axis must exceed the other by this ratio.
    public var axisDominance = 1.4
    /// After a flick, a stroke the opposite way within this window is treated as
    /// the hand returning, unless it is clearly more forceful.
    public var returnWindow = 0.6
    public var returnSpeedRatio = 1.4

    public init() {}
}

/// Recognizes quick strokes ("flicks") of the hand from its position track.
///
/// A stroke opens when speed crosses `startSpeed` and closes when the hand
/// decelerates or reverses. Only then is it judged, so a flick is reported about
/// one frame after the hand stops, with its peak velocity.
public struct FlickDetector: Sendable {
    public var config: FlickConfig

    private struct Stroke {
        var start: Double
        var origin: Vec2
        var last: Vec2
        var peakVelocity: Vec2
        var peakSpeed: Double
    }

    private var previous: (t: Double, p: Vec2)?
    private var velocity = Vec2.zero
    private var stroke: Stroke?
    private var mustRest = false
    public private(set) var lastFlick: Flick?
    /// The last stroke judged, and how many have been, so callers can log each once.
    public private(set) var lastStroke: StrokeReport?
    public private(set) var strokeCount = 0

    public init(config: FlickConfig = FlickConfig()) {
        self.config = config
    }

    public var inStroke: Bool { stroke != nil }

    /// Forget the current motion (e.g. the hand left the frame or started pinching).
    public mutating func reset() {
        previous = nil
        velocity = .zero
        stroke = nil
        mustRest = false
    }

    /// No stroke may start until the hand has slowed below `startSpeed`, so motion
    /// already under way (a hand entering the frame, or the tail of a pinch-drag)
    /// is never read as a flick.
    public mutating func requireRest() {
        stroke = nil
        mustRest = true
    }

    /// `position` is in hand units. `canStart` gates the start of new strokes (the
    /// hand must be open); a stroke already under way is allowed to finish.
    public mutating func update(position: Vec2, at t: Double, canStart: Bool) -> Flick? {
        defer { previous = (t, position) }
        guard let prev = previous, t > prev.t else { return nil }
        let raw = (position - prev.p) / (t - prev.t)
        velocity = velocity + (raw - velocity) * 0.6
        let speed = velocity.length

        if mustRest {
            if speed < config.startSpeed { mustRest = false }
            return nil
        }

        guard var s = stroke else {
            if canStart && speed > config.startSpeed {
                stroke = Stroke(start: prev.t, origin: prev.p, last: position, peakVelocity: velocity, peakSpeed: speed)
            }
            return nil
        }

        s.last = position
        if speed > s.peakSpeed {
            s.peakSpeed = speed
            s.peakVelocity = velocity
        }
        let limit = s.peakSpeed >= config.fastPeakSpeed ? config.maxFastDuration : config.maxDuration
        if t - s.start > limit {
            stroke = nil
            mustRest = true
            report(s, endedAt: t, .sweep)
            return nil
        }
        let reversed = velocity.dot(s.peakVelocity) < 0
        let decelerated = speed < config.endFraction * s.peakSpeed
        guard reversed || decelerated else {
            stroke = s
            return nil
        }
        stroke = nil
        return judge(s, endedAt: t)
    }

    private mutating func report(_ s: Stroke, endedAt t: Double, _ verdict: FlickVerdict) {
        lastStroke = StrokeReport(start: s.start, end: t, peakSpeed: s.peakSpeed, displacement: s.last - s.origin, verdict: verdict)
        strokeCount += 1
    }

    private mutating func judge(_ s: Stroke, endedAt t: Double) -> Flick? {
        let flick = evaluate(s, endedAt: t)
        report(s, endedAt: t, flick.verdict)
        return flick.flick
    }

    private mutating func evaluate(_ s: Stroke, endedAt t: Double) -> (flick: Flick?, verdict: FlickVerdict) {
        let d = s.last - s.origin
        let duration = t - s.start
        guard duration >= config.minDuration else { return (nil, .tooBrief) }
        guard s.peakSpeed >= config.minPeakSpeed else { return (nil, .tooSlow) }

        let axis: FlickAxis
        let along: Double
        if abs(d.y) >= config.axisDominance * abs(d.x) {
            axis = .vertical
            along = d.y
        } else if abs(d.x) >= config.axisDominance * abs(d.y) {
            axis = .horizontal
            along = d.x
        } else {
            return (nil, .offAxis)
        }
        guard abs(along) >= config.minDistance else { return (nil, .tooShort) }
        let sign: Double = along > 0 ? 1 : -1

        if let last = lastFlick, last.axis == axis, last.sign != sign,
           t - last.time < config.returnWindow,
           s.peakSpeed < last.peakSpeed * config.returnSpeedRatio {
            return (nil, .returnStroke)
        }

        let flick = Flick(axis: axis, sign: sign, peakSpeed: s.peakSpeed, distance: abs(along), time: t)
        lastFlick = flick
        return (flick, .flick)
    }
}
