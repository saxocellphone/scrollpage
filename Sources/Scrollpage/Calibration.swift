import Foundation
import ScrollpageCore

/// `Scrollpage --calibrate-pinch [--record file.jsonl]`
/// `Scrollpage --calibrate-pinch --replay file.jsonl`
///
/// Walks through a series of poses in the console (each starts on Enter, see
/// `GuidedRecorder`), records every frame with the pose it was asked for, and
/// reports the fingertip distances (in hand sizes) of each: touching, hovering
/// just apart, a fist, touching with the other fingers curled (which must not
/// count), and of the peace sign that toggles control. The left-hand step
/// checks which hand Vision calls which.
enum Calibration {
    struct Step {
        let label: String
        let prompt: String
        let seconds: Double
    }

    /// The start of each step that the report leaves out: in recordings the
    /// hand was still getting into the pose for about this long.
    static let settleSeconds = 1.5
    static let steps = [
        Step(label: "open", prompt: "Hold up your RIGHT hand, relaxed and open, about an arm's length from the camera.", seconds: 5.5),
        Step(label: "touch", prompt: "RIGHT hand: touch the TIPS of thumb and index finger together and keep them touching, the other fingers straight. Move the hand slowly.", seconds: 7.5),
        Step(label: "hover", prompt: "RIGHT hand: hold thumb and index tips as close as you can WITHOUT touching, a hair apart.", seconds: 7.5),
        Step(label: "fist", prompt: "RIGHT hand: make a FIST, then roll it and move it slowly.", seconds: 7.5),
        Step(label: "curled", prompt: "RIGHT hand: thumb and index tips touching again, but middle, ring and little finger curled into the palm (this must NOT count).", seconds: 6.5),
        Step(label: "peace", prompt: "RIGHT hand: make a peace sign (index and middle up in a V, thumb folded over the ring and little finger) and hold it still.", seconds: 5.5),
        Step(label: "left", prompt: "Lower your right hand and hold up only your LEFT hand, open.", seconds: 5.5),
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
        if let i = arguments.firstIndex(of: "--replay"), i + 1 < arguments.count {
            guard report(arguments[i + 1]) else { exit(1) }
            exit(0)
        }
        var recordPath = "/tmp/scrollpage-calibration-\(Int(Date().timeIntervalSince1970)).jsonl"
        if let i = arguments.firstIndex(of: "--record"), i + 1 < arguments.count { recordPath = arguments[i + 1] }
        GuidedRecorder.run(title: "Scrollpage pinch calibration. Sit where you normally would, in your usual light.",
                           steps: steps, recordPath: recordPath) { _ = report($0) }
    }

    /// Reports on a recorded calibration with the current thresholds.
    @discardableResult
    static func report(_ path: String) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("Can't read \(path)")
            return false
        }
        let session = Session()
        var steps = Steps()
        for object in GuidedRecording.frames(text) {
            guard let t = object["t"] as? Double, let label = object["label"] as? String,
                  let step = steps.step(label: label, at: t) else { continue }
            session.mirrored = object["mirrored"] as? Bool ?? session.mirrored
            if step.settled { session.add(Diagnostics.decodeHands(object), label: step.pose) } else { session.count(step.pose) }
        }
        print("\nCalibration recording \(path)")
        session.printReport()
        return true
    }

    final class Session {
        private struct Sample {
            var label: String
            var chirality: Chirality?
            var measure: TouchMeasure
            var handSize: Double
            var peace: PeaceSignMeasure
            var isPeace: Bool
            var fist: Bool
            var reach: Double?
        }

        private var samples: [Sample] = []
        private var order: [String] = []
        private var framesPerLabel: [String: Int] = [:]
        var mirrored = false
        private let toggle = ToggleGestureDetector()

        func count(_ label: String) {
            if !order.contains(label) { order.append(label) }
        }

        func add(_ hands: [HandSample], label: String) {
            count(label)
            framesPerLabel[label, default: 0] += 1
            // The biggest hand, whatever Vision calls it: the prompts say which hand it should be.
            if let hand = hands.filter({ $0.handSize != nil }).max(by: { $0.handSize! < $1.handSize! }), let size = hand.handSize {
                let fist = FistThresholds()
                let reach = FistDetector.tipReach(hand, handSize: size, minConfidence: fist.fingers.minConfidence)
                let curled = Finger.allCases.allSatisfy { hand.extensionReading($0, thresholds: fist.fingers) == .curled }
                samples.append(Sample(label: label, chirality: hand.chirality,
                                      measure: TouchMeasure(hand, handSize: size), handSize: size,
                                      peace: PeaceSignMeasure(hand, handSize: size), isPeace: toggle.isPeaceSign(hand, handSize: size),
                                      fist: curled && (reach.map { $0 <= fist.tipReachEnter } ?? false), reach: reach))
            }
        }

        func printReport() {
            let th = TouchThresholds()
            let fistTh = FistThresholds()
            func of(_ label: String) -> [Sample] { samples.filter { $0.label == label } }
            func readable(_ s: [Sample]) -> [Sample] { s.filter { $0.measure.readable } }
            func share(_ s: [Sample], _ test: (Sample) -> Bool) -> String {
                s.isEmpty ? "–" : "\(fmt(100 * Double(s.filter(test).count) / Double(s.count), 0)) %"
            }
            func dist(_ v: [Double]) -> String {
                "p5 \(fmt(percentile(v, 0.05), 3))  p10 \(fmt(percentile(v, 0.1), 3))  median \(fmt(percentile(v, 0.5), 3))  p90 \(fmt(percentile(v, 0.9), 3))  p95 \(fmt(percentile(v, 0.95), 3))"
            }

            print("\nPer pose (distances in hand sizes, wrist to middle knuckle; readable frames after each step's first \(fmt(settleSeconds)) s)")
            for label in order {
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
                if label == "fist", !all.isEmpty {
                    print("         fingertips' farthest reach from the knuckles \(dist(all.compactMap(\.reach)))  (fist ≤ \(fmt(fistTh.tipReachEnter, 2)), opens > \(fmt(fistTh.tipReachExit, 2)))")
                    print("         all four fingers curled in \(share(all) { $0.measure.curled.count == Finger.allCases.count })")
                }
                guard !r.isEmpty else { continue }
                print("         thumb–index   \(dist(r.compactMap(\.measure.thumbIndex)))")
                switch label {
                case "touch":
                    print("         middle gap    \(dist(r.compactMap(\.measure.middleGap)))")
                case "curled":
                    print("         middle, ring and little curled in \(share(r) { TouchDetector.liftedFingers.isSubset(of: $0.measure.curled) }), "
                        + "all extended in \(share(r) { TouchDetector.liftedFingers.isSubset(of: $0.measure.extended) })")
                default: break
                }
            }

            let touch = readable(of("touch")), hover = readable(of("hover")), curled = readable(of("curled"))
            let detector = TouchDetector(thresholds: th)
            print("\nThresholds: pinch starts ≤ \(fmt(th.pinchEnter, 2)), lets go > \(fmt(th.pinchExit, 2)), middle tip ≥ \(fmt(th.middleApart, 2)) away; "
                + "a fist needs all four fingers curled and every tip within \(fmt(fistTh.tipReachEnter, 2)) of the knuckles")
            print("  touching frames read as a pinch            \(share(touch) { detector.isPinch($0.measure) })  (want most)")
            print("  touching frames inside the pinch release   \(share(touch) { ($0.measure.thumbIndex ?? 1) <= th.pinchExit })  (want ~100 %)")
            print("  hovering frames read as a pinch            \(share(hover) { detector.isPinch($0.measure) })  (want ~0 %; a touch needs \(th.confirmFrames) in a row)")
            print("  hovering frames at or below a pinch start  \(share(hover) { ($0.measure.thumbIndex ?? 1) <= th.pinchEnter })  (want ~0 %)")
            print("  curled frames read as a pinch              \(share(curled) { detector.isPinch($0.measure) })  (want 0 % if those fingers were curled)")
            print("  fist frames read as a fist                 \(share(of("fist")) { $0.fist })  (want most; scrolling needs \(fistTh.confirmFrames) in a row)")
            print("  fist frames read as a pinch                \(share(readable(of("fist"))) { detector.isPinch($0.measure) })  (want 0 %)")
            for label in ["open", "touch", "hover", "three", "peace"] where !of(label).isEmpty {
                print("  \(label) frames read as a fist".padding(toLength: 45, withPad: " ", startingAt: 0) + "\(share(of(label)) { $0.fist })  (want 0 %)")
            }
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
