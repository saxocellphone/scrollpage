import Foundation
import ScrollpageCore

/// `Scrollpage --calibrate-pinch [--record file.jsonl]`
/// `Scrollpage --calibrate-pinch --replay file.jsonl`
///
/// Prompts for a series of poses in the console, records every frame with the
/// pose it was asked for, and reports the fingertip distances (in hand sizes)
/// of each: touching, hovering just apart, three fingertips together, touching
/// with the other fingers curled (which must not count), and of the peace sign
/// that toggles control. The left-hand step checks which hand Vision calls which.
enum Calibration {
    struct Step {
        let label: String
        let prompt: String
        /// Measured time, after `settleSeconds` to get into the pose.
        let seconds: Double
    }

    static let readySeconds = 3.0
    /// The start of each step that the report leaves out: in recordings the
    /// hand was still getting into the pose for about this long.
    static let settleSeconds = 1.5
    static let steps = [
        Step(label: "open", prompt: "Hold up your RIGHT hand, relaxed and open, about an arm's length from the camera.", seconds: 4),
        Step(label: "touch", prompt: "RIGHT hand: touch the TIPS of thumb and index finger together and keep them touching, the other fingers straight. Move the hand slowly.", seconds: 6),
        Step(label: "hover", prompt: "RIGHT hand: hold thumb and index tips as close as you can WITHOUT touching, a hair apart.", seconds: 6),
        Step(label: "three", prompt: "RIGHT hand: touch the TIPS of thumb, index AND middle finger together and keep them touching. Move slowly.", seconds: 6),
        Step(label: "curled", prompt: "RIGHT hand: thumb and index tips touching again, but middle, ring and little finger curled into the palm (this must NOT count).", seconds: 5),
        Step(label: "peace", prompt: "RIGHT hand: make a peace sign (index and middle up in a V, thumb folded over the ring and little finger) and hold it still.", seconds: 4),
        Step(label: "left", prompt: "Lower your right hand and hold up only your LEFT hand, open.", seconds: 4),
    ]

    /// Splits a recording's labelled frames into steps.
    struct Steps {
        private var current: String?
        private var start = 0.0
        private var seenThree = false

        /// The step a frame belongs to (nil between steps) and whether the hand
        /// has had `settleSeconds` to get into the pose.
        mutating func step(label: String, at t: Double) -> (pose: String, settled: Bool)? {
            guard label != "transition" else {
                current = nil
                return nil
            }
            if current == nil {
                // Recordings from before the curled step had its own label call it "touch".
                current = label == "touch" && seenThree ? "curled" : label
                start = t
                if label == "three" { seenThree = true }
            }
            return (current!, t - start >= settleSeconds)
        }
    }

    static func run(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        if let i = arguments.firstIndex(of: "--replay"), i + 1 < arguments.count { replay(arguments[i + 1]) }
        var recordPath = "/tmp/scrollpage-calibration-\(Int(Date().timeIntervalSince1970)).jsonl"
        if let i = arguments.firstIndex(of: "--record"), i + 1 < arguments.count { recordPath = arguments[i + 1] }
        let total = steps.reduce(0) { $0 + readySeconds + settleSeconds + $1.seconds }
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

    /// Reports on a recorded calibration with the current thresholds.
    private static func replay(_ path: String) -> Never {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("Can't read \(path)")
            exit(1)
        }
        let session = Session(recordPath: nil)
        var steps = Steps()
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = object["t"] as? Double, let label = object["label"] as? String,
                  let step = steps.step(label: label, at: t), step.settled else { continue }
            session.addSettled(Diagnostics.decodeHands(object), label: step.pose)
        }
        print("Calibration recording \(path)")
        session.printReport()
        exit(0)
    }

    /// Only touched on the camera queue.
    final class Session {
        private struct Sample {
            var label: String
            var chirality: Chirality?
            var measure: TouchMeasure
            var handSize: Double
            var peace: PeaceSignMeasure
            var isPeace: Bool
        }

        private var start: Double?
        private var announced = -1
        private var recording = false
        private var samples: [Sample] = []
        private var framesPerLabel: [String: Int] = [:]
        private var mirrored = false
        private let toggle = ToggleGestureDetector()
        private let recorder: FileHandle?

        init(recordPath: String?) {
            if let recordPath {
                FileManager.default.createFile(atPath: recordPath, contents: nil)
                recorder = FileHandle(forWritingAtPath: recordPath)
            } else {
                recorder = nil
            }
        }

        /// The step at `elapsed`, whether it is recording (past its countdown)
        /// and whether the hand has had time to settle into the pose.
        private func step(at elapsed: Double) -> (index: Int, recording: Bool, settled: Bool)? {
            var t = 0.0
            for (i, s) in Calibration.steps.enumerated() {
                if elapsed < t + readySeconds { return (i, false, false) }
                if elapsed < t + readySeconds + settleSeconds + s.seconds {
                    return (i, true, elapsed >= t + readySeconds + settleSeconds)
                }
                t += readySeconds + settleSeconds + s.seconds
            }
            return nil
        }

        func add(_ r: FrameReport) {
            if start == nil { start = r.time }
            mirrored = r.stats.imageMirrored
            guard let (index, isRecording, settled) = step(at: r.time - start!) else { return }
            let s = Calibration.steps[index]
            if index != announced {
                announced = index
                print("[\(index + 1)/\(Calibration.steps.count)] \(s.prompt)")
                print("      get ready…")
            }
            if isRecording && !recording { print("      ● recording \(Int(settleSeconds + s.seconds)) s") }
            recording = isRecording
            let label = isRecording ? s.label : "transition"

            if settled { addSettled(r.hands, label: label) }
            record(r, label: label)
        }

        func addSettled(_ hands: [HandSample], label: String) {
            framesPerLabel[label, default: 0] += 1
            // The biggest hand, whatever Vision calls it: the prompts say which hand it should be.
            if let hand = hands.filter({ $0.handSize != nil }).max(by: { $0.handSize! < $1.handSize! }), let size = hand.handSize {
                samples.append(Sample(label: label, chirality: hand.chirality,
                                      measure: TouchMeasure(hand, handSize: size), handSize: size,
                                      peace: PeaceSignMeasure(hand, handSize: size), isPeace: toggle.isPeaceSign(hand, handSize: size)))
            }
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
            func thumbNearest(_ m: TouchMeasure) -> Double? {
                guard let a = m.thumbIndex, let b = m.thumbMiddle else { return nil }
                return min(a, b)
            }

            print("\nPer pose (distances in hand sizes, wrist to middle knuckle; readable frames after each step's first \(fmt(settleSeconds)) s)")
            for label in Calibration.steps.map(\.label) {
                let all = of(label)
                let r = readable(all)
                let rights = all.filter { $0.chirality == .right }.count
                let lefts = all.filter { $0.chirality == .left }.count
                print("  \(label.padding(toLength: 6, withPad: " ", startingAt: 0)) \(all.count)/\(framesPerLabel[label] ?? 0) frames with a hand, \(r.count) readable; "
                    + "labelled right \(rights), left \(lefts), unknown \(all.count - rights - lefts); hand size median \(fmt(percentile(all.map(\.handSize), 0.5), 3))")
                if label == "peace", !all.isEmpty {
                    let pose = toggle.config.pose
                    print("         index–middle  \(dist(all.compactMap(\.peace.gap)))  (V ≥ \(fmt(pose.gapEnter, 2)))")
                    print("         V angle       \(dist(all.compactMap(\.peace.angle)))  (≥ \(fmt(pose.angleEnter, 0))°)")
                    print("         tips' reach   \(dist(all.compactMap(\.peace.reach)))  (≥ \(fmt(pose.reachEnter, 2)))")
                    print("         thumb to ring/little or palm \(dist(all.compactMap(\.peace.thumbNear)))  (≤ \(fmt(pose.thumbNearEnter, 2)))")
                    print("         thumb to the raised tips     \(dist(all.compactMap(\.peace.thumbApart)))  (≥ \(fmt(pose.thumbApartEnter, 2)))")
                    print("         thumb across the palm        \(dist(all.compactMap(\.peace.thumbAcross)))  (≥ \(fmt(pose.thumbAcrossEnter, 2)))")
                }
                guard !r.isEmpty else { continue }
                print("         thumb–index   \(dist(r.compactMap(\.measure.thumbIndex)))")
                switch label {
                case "three":
                    let m = r.filter(\.measure.middleReadable)
                    print("         thumb–middle  \(dist(m.compactMap(\.measure.thumbMiddle)))")
                    print("         index–middle  \(dist(m.compactMap(\.measure.indexMiddle)))")
                    print("         thumb–nearer  \(dist(m.compactMap { thumbNearest($0.measure) }))")
                    print("         middle tip readable in \(share(r) { $0.measure.middleReadable })")
                case "touch":
                    print("         middle gap    \(dist(r.compactMap(\.measure.middleGap)))")
                case "curled":
                    print("         middle, ring and little curled in \(share(r) { TouchKind.pinch.liftedFingers.isSubset(of: $0.measure.curled) }), "
                        + "all extended in \(share(r) { TouchKind.pinch.liftedFingers.isSubset(of: $0.measure.extended) })")
                default: break
                }
            }

            let touch = readable(of("touch")), hover = readable(of("hover")), three = readable(of("three")), curled = readable(of("curled"))
            let detector = TouchDetector(thresholds: th)
            print("\nThresholds: pinch starts ≤ \(fmt(th.pinchEnter, 2)), lets go > \(fmt(th.pinchExit, 2)), middle tip ≥ \(fmt(th.middleApart, 2)) away; "
                + "three-finger starts with thumb pairs ≤ \(fmt(th.threeEnter.thumb, 2)), index–middle ≤ \(fmt(th.threeEnter.indexMiddle, 2)) "
                + "and the thumb ≤ \(fmt(th.threeThumbContact, 2)) from the nearer tip, lets go > \(fmt(th.threeExit.thumb, 2)) / \(fmt(th.threeExit.indexMiddle, 2))")
            print("  touching frames read as a pinch            \(share(touch) { detector.pose($0.measure) == .pinch })  (want most)")
            print("  touching frames inside the pinch release   \(share(touch) { ($0.measure.thumbIndex ?? 1) <= th.pinchExit })  (want ~100 %)")
            print("  hovering frames read as a pinch            \(share(hover) { detector.pose($0.measure) == .pinch })  (want ~0 %; a touch needs \(th.confirmFrames) in a row)")
            print("  hovering frames at or below a pinch start  \(share(hover) { ($0.measure.thumbIndex ?? 1) <= th.pinchEnter })  (want ~0 %)")
            print("  three-finger frames read as three-finger   \(share(three) { detector.pose($0.measure) == .threeFinger })  (want most)")
            print("  three-finger frames read as a pinch        \(share(three) { detector.pose($0.measure) == .pinch })  (want 0 %)")
            print("  touching frames read as three-finger       \(share(touch) { detector.pose($0.measure) == .threeFinger })  (want 0 %)")
            print("  curled frames read as a pinch              \(share(curled) { detector.pose($0.measure) == .pinch })  (want 0 % if those fingers were curled)")
            print("  peace-sign frames read as a peace sign     \(share(of("peace")) { $0.isPeace })  (want most; the toggle needs \(fmt(toggle.config.holdDuration)) s of them)")
            print("  other right-hand frames read as one        \(share(samples.filter { $0.label != "peace" && $0.label != "left" }) { $0.isPeace })  (want 0 %)")

            let touchTop = percentile(touch.compactMap(\.measure.thumbIndex), 0.95)
            let hoverBottom = percentile(hover.compactMap(\.measure.thumbIndex), 0.05)
            if !touchTop.isNaN && !hoverBottom.isNaN {
                if touchTop < hoverBottom {
                    print("\nSuggested from this session: pinch starts ≤ \(fmt(touchTop + (hoverBottom - touchTop) * 0.25, 3)), "
                        + "lets go > \(fmt(touchTop + (hoverBottom - touchTop) * 0.6, 3)) (touching p95 \(fmt(touchTop, 3)), hovering p5 \(fmt(hoverBottom, 3)))")
                } else {
                    print("\nTouching and hovering overlap in this session (touching p95 \(fmt(touchTop, 3)) ≥ hovering p5 \(fmt(hoverBottom, 3))): "
                        + "the pinch start should sit below most hovering frames, and the release above most touching ones.")
                }
            }
            let held = three.filter(\.measure.middleReadable)
            let thumbTop = percentile(held.flatMap { [$0.measure.thumbIndex, $0.measure.thumbMiddle].compactMap { $0 } }, 0.9)
            let pairTop = percentile(held.compactMap(\.measure.indexMiddle), 0.9)
            let contactTop = percentile(held.compactMap { thumbNearest($0.measure) }, 0.95)
            if !thumbTop.isNaN {
                print("Three-finger p90: thumb pairs \(fmt(thumbTop, 3)) (start ≤ \(fmt(th.threeEnter.thumb, 2))), index–middle \(fmt(pairTop, 3)) "
                    + "(≤ \(fmt(th.threeEnter.indexMiddle, 2))); thumb to the nearer tip p95 \(fmt(contactTop, 3)) (≤ \(fmt(th.threeThumbContact, 2))). "
                    + "The thumb-pair start must stay at or below the pinch's middle-apart \(fmt(th.middleApart, 2)).")
            }

            let rightSteps = samples.filter { $0.label != "left" }
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
