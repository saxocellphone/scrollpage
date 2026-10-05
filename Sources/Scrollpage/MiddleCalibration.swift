import Foundation
import ScrollpageCore

/// `Scrollpage --calibrate-middle [--record file.jsonl]`
///
/// A guided recording of the thumb–middle pinch that scrolls: touching and
/// holding still, hovering a hair apart, holding while moving, quick taps
/// (one set with the index relaxed), and an OK pinch for contrast. Before each
/// step it waits until a right hand at the usual distance is in view, and a
/// step where the hand was mostly labelled left or too small is done again.
/// Every frame is saved with its step; rejected attempts as `<step>-rejected`.
enum MiddleCalibration {
    static let steps = [
        Calibration.Step(label: "middle-touch", prompt: "Palm facing the camera: touch your THUMB tip to your MIDDLE fingertip, INDEX finger straight UP, and hold still.", seconds: 5),
        Calibration.Step(label: "middle-hover", prompt: "Same hand shape, but hold the thumb a hair APART from the middle fingertip, not touching. Index still straight up.", seconds: 5),
        Calibration.Step(label: "middle-drag", prompt: "Touch thumb to middle finger again and KEEP touching while you move the hand slowly up, down, left and right, as if scrolling.", seconds: 8),
        Calibration.Step(label: "middle-taps", prompt: "Index straight up: tap thumb to middle finger quickly, several times (touch and let go).", seconds: 6),
        Calibration.Step(label: "middle-taps-relaxed", prompt: "Same quick thumb–middle taps, but let the INDEX finger relax (don't hold it straight).", seconds: 6),
        Calibration.Step(label: "ok", prompt: "For contrast: the normal OK pinch, thumb tip on INDEX tip, the other three fingers up. Hold it and move slowly.", seconds: 5),
    ]

    /// Smaller than this (image heights, wrist to middle knuckle) is farther
    /// away than the app is used from: 0.15 to 0.20 in earlier sessions.
    static let minHandSize = 0.12
    /// Hand in view, right, and big enough this long before a step starts.
    static let readyHold = 1.0
    /// A step with fewer good frames than this is done again.
    static let minGoodShare = 0.6
    static let maxAttempts = 2
    /// Ready check gives up waiting after this long and records anyway.
    static let maxWait = 25.0

    static func run(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        var recordPath = "/tmp/scrollpage-middle-\(Int(Date().timeIntervalSince1970)).jsonl"
        if let i = arguments.firstIndex(of: "--record"), i + 1 < arguments.count { recordPath = arguments[i + 1] }
        print("Scrollpage middle-finger pinch calibration (about a minute). Use your RIGHT hand, at your usual distance")
        print("from the camera, palm facing it. Each step starts once your right hand is seen. Recording to \(recordPath)\n")

        Diagnostics.withCamera {
            let pipeline = CameraPipeline()
            let session = Session(recordPath: recordPath)
            pipeline.onFrame = { session.add($0) }
            Diagnostics.startCamera(pipeline) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
                    pipeline.onFrame = nil
                    print("\nTimed out.")
                    pipeline.videoQueue.sync { session.printReport() }
                    exit(1)
                }
            }
        }
    }

    /// Only touched on the camera queue.
    final class Session {
        private enum Phase {
            /// `seen` is how long a hand has been in view while waiting: with
            /// none, the step waits for as long as it takes.
            case waiting(since: Double, seen: Double, last: Double, goodSince: Double?, lastStatus: Double)
            case recording(start: Double)
        }

        private struct Sample {
            var label: String
            var m: TouchMeasure
            var indexRatio: Double?
            var middleRatio: Double?
            var pose: TouchKind?
        }

        private var index = 0
        private var attempt = 1
        private var phase: Phase?
        private var buffered: [[String: Any]] = []
        private var good = 0
        private var total = 0
        private var samples: [Sample] = []
        private var pending: [Sample] = []
        private let recorder: FileHandle?

        init(recordPath: String) {
            FileManager.default.createFile(atPath: recordPath, contents: nil)
            recorder = FileHandle(forWritingAtPath: recordPath)
        }

        private func biggest(_ hands: [HandSample]) -> HandSample? {
            hands.filter { $0.handSize != nil }.max { $0.handSize! < $1.handSize! }
        }

        private func status(_ hand: HandSample?) -> (ok: Bool, text: String) {
            guard let hand, let size = hand.handSize else { return (false, "no hand in view") }
            let sizeText = "hand size \(fmt(size, 2))"
            if hand.chirality != .right {
                return (false, "hand labelled \(hand.chirality?.rawValue.uppercased() ?? "UNKNOWN"), \(sizeText): use your RIGHT hand, palm facing the camera")
            }
            if size < MiddleCalibration.minHandSize {
                return (false, "right hand, \(sizeText): too far, come closer (≥ \(fmt(MiddleCalibration.minHandSize, 2)))")
            }
            return (true, "right hand detected, \(sizeText) ✓")
        }

        func add(_ r: FrameReport) {
            guard index < MiddleCalibration.steps.count else { return }
            let step = MiddleCalibration.steps[index]
            let hand = biggest(r.hands)
            let check = status(hand)
            let t = r.time
            let line: [String: Any] = ["t": t, "hands": r.hands.map(Diagnostics.encode), "selected": NSNull(), "out": [String]()]

            switch phase {
            case nil:
                print("\n[\(index + 1)/\(MiddleCalibration.steps.count)] \(step.prompt)" + (attempt > 1 ? "  (attempt \(attempt))" : ""))
                phase = .waiting(since: t, seen: 0, last: t, goodSince: nil, lastStatus: -.infinity)
                write(line, label: "transition")
            case let .waiting(since, seen, last, goodSince, lastStatus):
                write(line, label: "transition")
                let okSince = check.ok ? (goodSince ?? t) : nil
                let seenNow = seen + (hand == nil ? 0 : t - last)
                var shown = lastStatus
                if t - lastStatus >= (hand == nil ? 5 : 1) {
                    print("      \(check.text)")
                    shown = t
                }
                let ready = t - since >= Calibration.readySeconds && okSince.map { t - $0 >= MiddleCalibration.readyHold } == true
                let gaveUp = seenNow >= MiddleCalibration.maxWait
                if ready || gaveUp {
                    if gaveUp && !ready { print("      still not a clear right hand; recording anyway") }
                    print("      ● recording \(Int(Calibration.settleSeconds + step.seconds)) s")
                    phase = .recording(start: t)
                    buffered = []
                    pending = []
                    good = 0
                    total = 0
                } else {
                    phase = .waiting(since: since, seen: seenNow, last: t, goodSince: okSince, lastStatus: shown)
                }
            case let .recording(start):
                var l = line
                l["label"] = step.label
                buffered.append(l)
                if t - start >= Calibration.settleSeconds {
                    total += 1
                    if check.ok { good += 1 }
                    if let hand, let size = hand.handSize {
                        let m = TouchMeasure(hand, handSize: size)
                        pending.append(Sample(label: step.label, m: m,
                                              indexRatio: hand.extensionRatio(.index), middleRatio: hand.extensionRatio(.middle),
                                              pose: TouchDetector().pose(m)))
                    }
                }
                guard t - start >= Calibration.settleSeconds + step.seconds else { return }
                let share = total == 0 ? 0 : Double(good) / Double(total)
                let accepted = share >= MiddleCalibration.minGoodShare || attempt >= MiddleCalibration.maxAttempts
                for var l in buffered {
                    if !accepted { l["label"] = "\(step.label)-rejected" }
                    writeLine(l)
                }
                buffered = []
                if accepted {
                    if share < MiddleCalibration.minGoodShare {
                        print("      only \(fmt(100 * share, 0)) % of frames showed a right hand at the usual size; keeping it after \(attempt) attempts")
                    } else {
                        print("      done (\(fmt(100 * share, 0)) % of frames a clear right hand)")
                    }
                    samples += pending
                    index += 1
                    attempt = 1
                } else {
                    print("      only \(fmt(100 * share, 0)) % of frames showed a right hand at the usual size; let's do this step again")
                    attempt += 1
                }
                pending = []
                phase = nil
                if index == MiddleCalibration.steps.count {
                    printReport()
                    exit(0)
                }
            }
        }

        private func write(_ line: [String: Any], label: String) {
            var l = line
            l["label"] = label
            writeLine(l)
        }

        private func writeLine(_ line: [String: Any]) {
            guard let recorder, let data = try? JSONSerialization.data(withJSONObject: line), let nl = "\n".data(using: .utf8) else { return }
            recorder.write(data)
            recorder.write(nl)
        }

        func printReport() {
            func dist(_ v: [Double]) -> String {
                v.isEmpty ? "–" : "p5 \(fmt(percentile(v, 0.05), 3))  median \(fmt(percentile(v, 0.5), 3))  p95 \(fmt(percentile(v, 0.95), 3))"
            }
            print("\nPer step (distances in hand sizes; frames after each step's first \(fmt(Calibration.settleSeconds)) s)")
            for label in MiddleCalibration.steps.map(\.label) {
                let s = samples.filter { $0.label == label }
                guard !s.isEmpty else {
                    print("  \(label): no hand")
                    continue
                }
                let share = { (test: (Sample) -> Bool) in "\(fmt(100 * Double(s.filter(test).count) / Double(s.count), 0)) %" }
                print("  \(label)  \(s.count) frames; read as an OK pinch by the current detector in \(share { $0.pose == .pinch })")
                print("      thumb–middle   \(dist(s.compactMap(\.m.thumbMiddle)))")
                print("      thumb–index    \(dist(s.compactMap(\.m.thumbIndex)))")
                print("      index–middle   \(dist(s.compactMap(\.m.indexMiddle)))")
                print("      index extension (tip/middle-joint from wrist)   \(dist(s.compactMap(\.indexRatio)))")
                print("      middle extension                                \(dist(s.compactMap(\.middleRatio)))")
            }
        }
    }
}
