import Foundation
import ScrollpageCore

/// `Scrollpage --calibrate-twist [--record file.jsonl]`
///
/// A short guided recording of the hand turning while it holds the OK-sign
/// pinch: still, clockwise and back, counter-clockwise and back, still. Every
/// frame is saved with its step, and the summary shows how far each step moved
/// the in-image hand angle, the palm's width (which narrows as the forearm
/// twists) and the hand's length (which shortens as it tips toward the camera),
/// relative to the first still step.
enum TwistCalibration {
    static let steps = [
        Calibration.Step(label: "still", prompt: "Make the OK pinch with your RIGHT hand (thumb and index tips touching, other fingers up) and hold still.", seconds: 3),
        Calibration.Step(label: "clockwise", prompt: "Keep the pinch. Rotate your hand CLOCKWISE (as you see it) and back, slowly, a few times.", seconds: 6),
        Calibration.Step(label: "counter", prompt: "Keep the pinch. Rotate your hand COUNTER-CLOCKWISE (as you see it) and back, slowly, a few times.", seconds: 6),
        Calibration.Step(label: "hold", prompt: "Keep the pinch and hold still.", seconds: 3),
    ]

    static func run(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        var recordPath = "/tmp/scrollpage-twist-\(Int(Date().timeIntervalSince1970)).jsonl"
        if let i = arguments.firstIndex(of: "--record"), i + 1 < arguments.count { recordPath = arguments[i + 1] }
        let ready = Calibration.readySeconds, settle = Calibration.settleSeconds
        let total = steps.reduce(0) { $0 + ready + settle + $1.seconds }
        print("Scrollpage twist calibration (\(Int(total)) s). Follow the prompts; each step is recorded after a \(Int(ready)) s countdown.")
        print("Sit where you normally would. Recording to \(recordPath)\n")

        Diagnostics.withCamera {
            let pipeline = CameraPipeline()
            let session = Session(recordPath: recordPath)
            pipeline.onFrame = { session.add($0) }
            Diagnostics.startCamera(pipeline) {
                DispatchQueue.main.asyncAfter(deadline: .now() + total + 0.5) {
                    pipeline.onFrame = nil
                    pipeline.videoQueue.sync { session.printReport() }
                    exit(0)
                }
            }
        }
    }

    /// Only touched on the camera queue.
    final class Session {
        private struct Sample {
            var label: String
            var angle: Double
            var width: Double
            var length: Double
            var pinched: Bool
            var right: Bool
        }

        private var start: Double?
        private var announced = -1
        private var recording = false
        private var samples: [Sample] = []
        private let recorder: FileHandle?

        init(recordPath: String) {
            FileManager.default.createFile(atPath: recordPath, contents: nil)
            recorder = FileHandle(forWritingAtPath: recordPath)
        }

        private func step(at elapsed: Double) -> (index: Int, recording: Bool, settled: Bool)? {
            var t = 0.0
            let ready = Calibration.readySeconds, settle = Calibration.settleSeconds
            for (i, s) in TwistCalibration.steps.enumerated() {
                if elapsed < t + ready { return (i, false, false) }
                if elapsed < t + ready + settle + s.seconds { return (i, true, elapsed >= t + ready + settle) }
                t += ready + settle + s.seconds
            }
            return nil
        }

        func add(_ r: FrameReport) {
            if start == nil { start = r.time }
            guard let (index, isRecording, settled) = step(at: r.time - start!) else { return }
            let s = TwistCalibration.steps[index]
            if index != announced {
                announced = index
                print("\n[\(index + 1)/\(TwistCalibration.steps.count)] \(s.prompt)")
                print("      get ready…")
            }
            if isRecording && !recording { print("      ● recording \(Int(Calibration.settleSeconds + s.seconds)) s") }
            recording = isRecording
            let label = isRecording ? s.label : "transition"
            if settled, let hand = r.hands.filter({ $0.handSize != nil }).max(by: { $0.handSize! < $1.handSize! }) {
                addSample(hand, label: label)
            }
            guard let recorder else { return }
            let line: [String: Any] = ["t": r.time, "label": label, "hands": r.hands.map(Diagnostics.encode),
                                       "selected": NSNull(), "out": [String]()]
            if let data = try? JSONSerialization.data(withJSONObject: line), let nl = "\n".data(using: .utf8) {
                recorder.write(data)
                recorder.write(nl)
            }
        }

        private func addSample(_ hand: HandSample, label: String) {
            guard let size = hand.handSize, let wrist = hand.location(.wrist), let index = hand.location(.indexMCP),
                  let middle = hand.location(.middleMCP), let little = hand.location(.littleMCP) else { return }
            let axis = (index + middle) * 0.5 - wrist
            let pinched = TouchDetector().pose(TouchMeasure(hand, handSize: size)) == .pinch
            samples.append(Sample(label: label, angle: atan2(axis.x, -axis.y) * 180 / .pi,
                                  width: index.distance(to: little) / axis.length, length: axis.length,
                                  pinched: pinched, right: hand.chirality == .right))
        }

        func printReport() {
            func of(_ label: String) -> [Sample] { samples.filter { $0.label == label } }
            let base = of("still")
            let a0 = percentile(base.map(\.angle), 0.5), w0 = percentile(base.map(\.width), 0.5), l0 = percentile(base.map(\.length), 0.5)
            func dist(_ v: [Double]) -> String {
                "p5 \(fmt(percentile(v, 0.05), 2))  median \(fmt(percentile(v, 0.5), 2))  p95 \(fmt(percentile(v, 0.95), 2))"
            }
            print("\nPer step, relative to the first still step (frames after each step's first \(fmt(Calibration.settleSeconds)) s)")
            for label in TwistCalibration.steps.map(\.label) {
                let s = of(label)
                guard !s.isEmpty else {
                    print("  \(label): no hand")
                    continue
                }
                let share = { (test: (Sample) -> Bool) in "\(fmt(100 * Double(s.filter(test).count) / Double(s.count), 0)) %" }
                print("  \(label.padding(toLength: 9, withPad: " ", startingAt: 0)) \(s.count) frames, pinched \(share(\.pinched)), labelled right \(share(\.right))")
                print("            in-image angle, degrees (+ is clockwise on screen)  \(dist(s.map { $0.angle - a0 }))")
                print("            palm width / hand length, % change                  \(dist(s.map { 100 * ($0.width / w0 - 1) }))")
                print("            hand length, % change                               \(dist(s.map { 100 * ($0.length / l0 - 1) }))")
            }
        }
    }
}
