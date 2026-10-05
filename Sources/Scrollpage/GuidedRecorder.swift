import Foundation
import ScrollpageCore

/// The console side of the `--calibrate-*` recorders: each step waits for
/// Enter, counts down, records for its duration and prints a one-line summary.
/// `r` + Enter redoes the last completed step, `q` + Enter (or end of input)
/// stops and keeps what was recorded. Any hand counts, whatever Vision calls
/// it; if there are two, the bigger one. Every frame is written with its step,
/// the step's attempt number and each hand's raw label and joint confidences;
/// a redone attempt is marked by a `superseded` line.
///
/// Calibration tooling only: the app itself takes no keyboard input.
enum GuidedRecorder {
    static let countdown = 2.0

    static func run(title: String, steps: [Calibration.Step], recordPath: String) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        print(title)
        print("Recording to \(recordPath)")
        print("Each step waits for Enter, then counts down \(Int(countdown)) s and records. r = redo previous step, q = quit.")

        Diagnostics.withCamera {
            let pipeline = CameraPipeline()
            let session = Session(steps: steps, recordPath: recordPath)
            pipeline.onFrame = { session.add($0) }
            Diagnostics.startCamera(pipeline) {
                pipeline.videoQueue.async { session.prompt() }
                Thread.detachNewThread {
                    while true {
                        let line = readLine()
                        pipeline.videoQueue.async { session.command(line) }
                        if line == nil { return }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1800) {
                    pipeline.videoQueue.async {
                        print("\nTimed out.")
                        session.finish()
                    }
                }
            }
        }
    }

    /// Only touched on the camera queue.
    final class Session {
        private enum Phase {
            case idle
            case countdown(start: Double)
            case recording(start: Double)
        }

        private struct Frame {
            var size: Double?
            var chirality: String
            var pinch: Bool
            var fist: Bool
        }

        private let steps: [Calibration.Step]
        private var index = 0
        private var attempts: [Int]
        private var phase = Phase.idle
        private var startRequested = false
        private var frames: [Frame] = []
        private var tick = -1
        private var lastTime = 0.0
        private let recorder: FileHandle?

        init(steps: [Calibration.Step], recordPath: String) {
            self.steps = steps
            attempts = Array(repeating: 0, count: steps.count)
            FileManager.default.createFile(atPath: recordPath, contents: nil)
            recorder = FileHandle(forWritingAtPath: recordPath)
        }

        func prompt() {
            if index < steps.count {
                print("\n[\(index + 1)/\(steps.count)] \(steps[index].prompt)  (\(fmt(steps[index].seconds, 0)) s)"
                    + (attempts[index] > 0 ? "  [redo, attempt \(attempts[index] + 1)]" : ""))
                print("Press Enter to start (r = redo previous step, q = quit)")
            } else {
                print("\nAll steps done. Press Enter to finish (r = redo previous step, q = quit)")
            }
        }

        func command(_ line: String?) {
            let cmd = line?.trimmingCharacters(in: .whitespaces).lowercased()
            if cmd == nil || cmd == "q" {
                if case .recording = phase { print("      stopped mid-step; its frames are kept, marked incomplete") }
                if case .recording = phase { writeLine(["event": "incomplete", "label": steps[index].label, "attempt": attempts[index] + 1, "t": lastTime]) }
                finish()
            }
            guard case .idle = phase else {
                print("      (recording; input ignored until the step ends)")
                return
            }
            if cmd == "r" {
                guard index > 0 else {
                    print("      nothing to redo yet")
                    prompt()
                    return
                }
                index -= 1
                attempts[index] += 1
                writeLine(["event": "superseded", "label": steps[index].label, "attempt": attempts[index], "t": lastTime])
                print("      redoing step \(index + 1); attempt \(attempts[index]) is superseded")
                prompt()
                return
            }
            if index >= steps.count { finish() }
            startRequested = true
        }

        func add(_ r: FrameReport) {
            let t = r.time
            lastTime = t
            let hand = r.hands.filter { $0.handSize != nil }.max { $0.handSize! < $1.handSize! }
            var line: [String: Any] = ["t": t, "hands": r.hands.map(Session.encode), "sizes": r.hands.map { $0.handSize ?? -1 },
                                       "mirrored": r.stats.imageMirrored, "selected": NSNull(), "out": [String]()]
            if startRequested {
                startRequested = false
                phase = .countdown(start: t)
                frames = []
                tick = -1
            }
            switch phase {
            case .idle:
                line["label"] = "transition"
            case let .countdown(start):
                line["label"] = "transition"
                let left = Int((GuidedRecorder.countdown - (t - start)).rounded(.up))
                if left != tick && left > 0 {
                    tick = left
                    print("      get ready… \(left)")
                }
                if t - start >= GuidedRecorder.countdown {
                    print("      ● recording \(fmt(steps[index].seconds, 0)) s")
                    phase = .recording(start: t)
                    tick = -1
                }
            case let .recording(start):
                let step = steps[index]
                line["label"] = step.label
                line["attempt"] = attempts[index] + 1
                let left = Int((step.seconds - (t - start)).rounded(.up))
                if left != tick && left > 0 {
                    tick = left
                    print("      \(left)")
                }
                let kind = hand.flatMap { h in h.handSize.map { TouchDetector().pose(TouchMeasure(h, handSize: $0)) } }
                let curled = hand.map { h in Finger.allCases.allSatisfy { h.extensionReading($0) == .curled } } ?? false
                frames.append(Frame(size: hand?.handSize, chirality: hand?.chirality?.rawValue ?? (hand == nil ? "none" : "unknown"),
                                    pinch: kind == .pinch, fist: curled))
                if t - start >= step.seconds {
                    writeLine(line)
                    summarize()
                    index += 1
                    phase = .idle
                    prompt()
                    return
                }
            }
            writeLine(line)
        }

        private func summarize() {
            let withHand = frames.filter { $0.size != nil }
            let sizes = withHand.compactMap(\.size)
            var labels: [String: Int] = [:]
            for f in withHand { labels[f.chirality, default: 0] += 1 }
            let share = { (n: Int) in withHand.isEmpty ? "–" : "\(fmt(100 * Double(n) / Double(withHand.count), 0)) %" }
            print("      done: \(withHand.count)/\(frames.count) frames with a hand, median hand size \(fmt(percentile(sizes, 0.5), 3)), "
                + "labelled \(labels.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")); "
                + "OK pinch \(share(withHand.filter(\.pinch).count)), all four fingers curled \(share(withHand.filter(\.fist).count))")
        }

        func finish() -> Never {
            recorder?.synchronizeFile()
            print("\nRecording finished (\(index) of \(steps.count) steps).")
            exit(0)
        }

        private static func encode(_ hand: HandSample) -> [String: Any] {
            var e = Diagnostics.encode(hand)
            e["handSizeConfidence"] = hand.handSizeConfidence ?? NSNull()
            return e
        }

        private func writeLine(_ line: [String: Any]) {
            guard let recorder, let data = try? JSONSerialization.data(withJSONObject: line), let nl = "\n".data(using: .utf8) else { return }
            recorder.write(data)
            recorder.write(nl)
        }
    }
}
