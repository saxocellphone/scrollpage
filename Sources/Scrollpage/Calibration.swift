import Foundation
import ScrollpageCore

/// `Scrollpage --calibrate-pinch [--record file.jsonl]`
///
/// Prompts for a series of poses in the console, records every frame with the
/// pose it was asked for, and reports the fingertip distances (in hand sizes)
/// of each: touching, hovering just apart, three fingertips together. The
/// left-hand step checks which hand Vision calls which.
enum Calibration {
    struct Step {
        let label: String
        let prompt: String
        let seconds: Double
    }

    static let readySeconds = 3.0
    static let steps = [
        Step(label: "open", prompt: "Hold up your RIGHT hand, relaxed and open, about an arm's length from the camera.", seconds: 4),
        Step(label: "touch", prompt: "RIGHT hand: touch the TIPS of thumb and index finger together and keep them touching. Move the hand slowly.", seconds: 6),
        Step(label: "hover", prompt: "RIGHT hand: hold thumb and index tips as close as you can WITHOUT touching, a hair apart.", seconds: 6),
        Step(label: "three", prompt: "RIGHT hand: touch the TIPS of thumb, index AND middle finger together and keep them touching. Move slowly.", seconds: 6),
        Step(label: "touch", prompt: "RIGHT hand: thumb and index tips touching again, the other fingers curled this time.", seconds: 5),
        Step(label: "left", prompt: "Lower your right hand and hold up only your LEFT hand, open.", seconds: 4),
    ]

    static func run(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        var recordPath = "/tmp/scrollpage-calibration-\(Int(Date().timeIntervalSince1970)).jsonl"
        if let i = arguments.firstIndex(of: "--record"), i + 1 < arguments.count { recordPath = arguments[i + 1] }
        let total = steps.reduce(0) { $0 + readySeconds + $1.seconds }
        print("Scrollpage pinch calibration (\(Int(total)) s). Follow the prompts; each pose is recorded after a \(Int(readySeconds)) s countdown.")
        print("Sit where you normally would, in your usual light. Recording to \(recordPath)\n")

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
            var chirality: Chirality?
            var measure: TouchMeasure
            var handSize: Double
        }

        private var start: Double?
        private var announced = -1
        private var recording = false
        private var samples: [Sample] = []
        private var framesPerLabel: [String: Int] = [:]
        private var mirrored = false
        private let recorder: FileHandle?

        init(recordPath: String) {
            FileManager.default.createFile(atPath: recordPath, contents: nil)
            recorder = FileHandle(forWritingAtPath: recordPath)
        }

        /// The step and whether it is recording (past its countdown) at `elapsed`.
        private func step(at elapsed: Double) -> (index: Int, recording: Bool)? {
            var t = 0.0
            for (i, s) in Calibration.steps.enumerated() {
                if elapsed < t + readySeconds { return (i, false) }
                if elapsed < t + readySeconds + s.seconds { return (i, true) }
                t += readySeconds + s.seconds
            }
            return nil
        }

        func add(_ r: FrameReport) {
            if start == nil { start = r.time }
            mirrored = r.stats.imageMirrored
            guard let (index, isRecording) = step(at: r.time - start!) else { return }
            let s = Calibration.steps[index]
            if index != announced {
                announced = index
                print("[\(index + 1)/\(Calibration.steps.count)] \(s.prompt)")
                print("      get ready…")
            }
            if isRecording && !recording { print("      ● recording \(Int(s.seconds)) s") }
            recording = isRecording
            let label = isRecording ? s.label : "transition"

            // The biggest hand, whatever Vision calls it: the prompts say which hand it should be.
            let hand = r.hands.filter { $0.handSize != nil }.max { $0.handSize! < $1.handSize! }
            if isRecording {
                framesPerLabel[label, default: 0] += 1
                if let hand, let size = hand.handSize {
                    samples.append(Sample(label: label, chirality: hand.chirality,
                                          measure: TouchMeasure(hand, handSize: size), handSize: size))
                }
            }
            record(r, label: label)
        }

        private func record(_ r: FrameReport, label: String) {
            guard let recorder else { return }
            let line: [String: Any] = ["t": r.time, "label": label, "hands": r.hands.map(Diagnostics.encode),
                                       "selected": NSNull(), "out": [String]()]
            if let data = try? JSONSerialization.data(withJSONObject: line), let nl = "\n".data(using: .utf8) {
                recorder.write(data)
                recorder.write(nl)
            }
        }

        func printReport() {
            let th = TouchThresholds()
            func of(_ label: String) -> [Sample] { samples.filter { $0.label == label } }
            func readable(_ s: [Sample]) -> [Sample] { s.filter { $0.measure.readable } }
            func share(_ s: [Sample], _ test: (Sample) -> Bool) -> String {
                s.isEmpty ? "–" : "\(fmt(100 * Double(s.filter(test).count) / Double(s.count), 0)) %"
            }
            func dist(_ v: [Double]) -> String {
                "p5 \(fmt(percentile(v, 0.05), 3))  p10 \(fmt(percentile(v, 0.1), 3))  median \(fmt(percentile(v, 0.5), 3))  p90 \(fmt(percentile(v, 0.9), 3))  p95 \(fmt(percentile(v, 0.95), 3))"
            }

            print("\nPer pose (distances in hand sizes, wrist to middle knuckle; readable frames only)")
            for label in ["open", "touch", "hover", "three", "left"] {
                let all = of(label)
                let r = readable(all)
                let rights = all.filter { $0.chirality == .right }.count
                let lefts = all.filter { $0.chirality == .left }.count
                print("  \(label.padding(toLength: 6, withPad: " ", startingAt: 0)) \(all.count)/\(framesPerLabel[label] ?? 0) frames with a hand, \(r.count) readable; "
                    + "labelled right \(rights), left \(lefts), unknown \(all.count - rights - lefts); hand size median \(fmt(percentile(all.map(\.handSize), 0.5), 3))")
                guard !r.isEmpty else { continue }
                print("         thumb–index   \(dist(r.compactMap(\.measure.thumbIndex)))")
                if label == "three" {
                    print("         thumb–middle  \(dist(r.compactMap(\.measure.thumbMiddle)))")
                    print("         index–middle  \(dist(r.compactMap(\.measure.indexMiddle)))")
                    print("         widest of 3   \(dist(r.compactMap(\.measure.threeSpread)))")
                } else if label == "touch" {
                    print("         middle gap    \(dist(r.compactMap(\.measure.middleGap)))")
                }
            }

            let touch = readable(of("touch")), hover = readable(of("hover")), three = readable(of("three"))
            let detector = TouchDetector(thresholds: th)
            print("\nCurrent thresholds: pinch touch < \(fmt(th.pinchEnter, 2)), release > \(fmt(th.pinchExit, 2)), "
                + "middle apart ≥ \(fmt(th.middleApart, 2)); three-finger touch < \(fmt(th.threeEnter, 2)), release > \(fmt(th.threeExit, 2))")
            print("  touching frames read as a pinch            \(share(touch) { detector.pose($0.measure) == .pinch })  (want most)")
            print("  touching frames inside the pinch release   \(share(touch) { ($0.measure.thumbIndex ?? 1) <= th.pinchExit })  (want ~100 %)")
            print("  hovering frames read as a pinch            \(share(hover) { detector.pose($0.measure) == .pinch })  (want 0 %)")
            print("  hovering frames inside the pinch release   \(share(hover) { ($0.measure.thumbIndex ?? 0) <= th.pinchExit })  (want ~0 %)")
            print("  three-finger frames read as three-finger   \(share(three) { detector.pose($0.measure) == .threeFinger })  (want most)")
            print("  three-finger frames read as a pinch        \(share(three) { detector.pose($0.measure) == .pinch })  (want 0 %)")
            print("  touching frames read as three-finger       \(share(touch) { detector.pose($0.measure) == .threeFinger })  (want 0 %)")

            let touchTop = percentile(touch.compactMap(\.measure.thumbIndex), 0.95)
            let hoverBottom = percentile(hover.compactMap(\.measure.thumbIndex), 0.05)
            if !touchTop.isNaN && !hoverBottom.isNaN {
                if touchTop < hoverBottom {
                    print("\nSuggested from this session: pinch touch < \(fmt(touchTop + (hoverBottom - touchTop) * 0.25, 3)), "
                        + "release > \(fmt(touchTop + (hoverBottom - touchTop) * 0.6, 3)) (touching p95 \(fmt(touchTop, 3)), hovering p5 \(fmt(hoverBottom, 3)))")
                } else {
                    print("\nTouching and hovering overlap in this session (touching p95 \(fmt(touchTop, 3)) ≥ hovering p5 \(fmt(hoverBottom, 3))): sit closer or add light.")
                }
            }
            let threeTop = percentile(three.compactMap(\.measure.threeSpread), 0.9)
            if !threeTop.isNaN { print("Three-finger widest distance p90 \(fmt(threeTop, 3)): the three-finger touch threshold should be above it and below \(fmt(th.middleApart, 2)).") }

            let rightSteps = samples.filter { ["open", "touch", "hover", "three"].contains($0.label) }
            let leftStep = of("left")
            let rightOK = rightSteps.filter { $0.chirality == .right }.count
            let leftOK = leftStep.filter { $0.chirality == .left }.count
            print("\nChirality (\(mirrored ? "mirrored" : "unmirrored") frames): right-hand steps labelled right in \(share(rightSteps) { $0.chirality == .right }), "
                + "left-hand step labelled left in \(share(leftStep) { $0.chirality == .left })")
            if !rightSteps.isEmpty && !leftStep.isEmpty {
                let good = Double(rightOK) / Double(rightSteps.count) > 0.8 && Double(leftOK) / Double(leftStep.count) > 0.8
                let inverted = Double(rightOK) / Double(rightSteps.count) < 0.2 && Double(leftOK) / Double(leftStep.count) < 0.2
                print(good ? "  The mapping is right: only your right hand will drive gestures."
                    : inverted ? "  The labels are inverted: your left hand would drive gestures. Please report this."
                    : "  The labels are unreliable in this session; check the R/L tag in the preview window.")
            }
        }
    }
}
