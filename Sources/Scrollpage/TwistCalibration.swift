import Foundation
import ScrollpageCore

/// `Scrollpage --calibrate-twist [--record file.jsonl]`
/// `Scrollpage --calibrate-twist --replay file.jsonl`
///
/// A short guided recording of the forearm rolling while the hand holds the
/// OK-sign pinch: still, palm up and back, palm down and back, still. The
/// summary shows, relative to the first still step, how far each step moved
/// the palm's width ratio (`ForearmTwist`'s signal) and the hand's in-image
/// angle (`WristRotation`'s), and how often the pinch held.
enum TwistCalibration {
    static let steps = [
        Calibration.Step(label: "still", prompt: "RIGHT hand, start edge-on. Make the OK pinch (thumb and index tips touching) and hold still.", seconds: 3),
        Calibration.Step(label: "up", prompt: "Keep the pinch. Roll your palm UP toward the ceiling, then back to edge-on. Slowly, 2-3 times.", seconds: 8),
        Calibration.Step(label: "down", prompt: "Keep the pinch. Roll your palm DOWN toward the floor, then back to edge-on. Slowly, 2-3 times.", seconds: 8),
        Calibration.Step(label: "hold", prompt: "Keep the pinch and hold still.", seconds: 3),
    ]

    static func run(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        if let i = arguments.firstIndex(of: "--replay"), i + 1 < arguments.count { exit(report(arguments[i + 1]) ? 0 : 1) }
        var recordPath = "/tmp/scrollpage-twist-\(Int(Date().timeIntervalSince1970)).jsonl"
        if let i = arguments.firstIndex(of: "--record"), i + 1 < arguments.count { recordPath = arguments[i + 1] }
        GuidedRecorder.run(title: "Scrollpage twist calibration. RIGHT hand, start edge-on; keep the OK pinch held throughout.",
                           steps: steps, recordPath: recordPath) { _ = report($0) }
    }

    private struct Sample {
        var label: String
        var angle: Double
        var width: Double
        var pinched: Bool
    }

    @discardableResult
    static func report(_ path: String) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("Can't read \(path)")
            return false
        }
        let c = ForearmTwistConfig().minConfidence
        var samples: [Sample] = []
        for object in GuidedRecording.frames(text) {
            guard let label = object["label"] as? String, label != "transition",
                  let hand = Diagnostics.decodeHands(object).filter({ $0.handSize != nil }).max(by: { $0.handSize! < $1.handSize! }),
                  let size = hand.handSize, let width = ForearmTwist.widthRatio(hand, minConfidence: c),
                  let wrist = hand.location(.wrist, minConfidence: c), let index = hand.location(.indexMCP, minConfidence: c),
                  let middle = hand.location(.middleMCP, minConfidence: c) else { continue }
            let axis = (index + middle) * 0.5 - wrist
            samples.append(Sample(label: label, angle: atan2(axis.x, -axis.y) * 180 / .pi, width: width,
                                  pinched: TouchDetector().isPinch(TouchMeasure(hand, handSize: size))))
        }
        func of(_ label: String) -> [Sample] { samples.filter { $0.label == label } }
        let base = of("still")
        let a0 = percentile(base.map(\.angle), 0.5), w0 = percentile(base.map(\.width), 0.5)
        func dist(_ v: [Double]) -> String {
            "p5 \(fmt(percentile(v, 0.05), 1))  median \(fmt(percentile(v, 0.5), 1))  p95 \(fmt(percentile(v, 0.95), 1))"
        }
        print("\nTwist recording \(path): per step, relative to the first still step (width ratio there \(fmt(w0, 3)))")
        for label in steps.map(\.label) {
            let s = of(label)
            guard !s.isEmpty else {
                print("  \(label): no hand")
                continue
            }
            let pinched = 100 * Double(s.filter(\.pinched).count) / Double(s.count)
            print("  \(label.padding(toLength: 6, withPad: " ", startingAt: 0)) \(s.count) frames, pinch pose \(fmt(pinched, 0)) %")
            print("         palm width ratio, % change (up narrows, down widens)  \(dist(s.map { 100 * ($0.width / w0 - 1) }))")
            print("         in-image angle, degrees (+ is clockwise)              \(dist(s.map { $0.angle - a0 }))")
        }
        return true
    }
}
