import AVFoundation
import Foundation
import ScrollpageCore

/// `Scrollpage --diagnose [seconds] [--record file.jsonl]`
/// `Scrollpage --diagnose --replay file.jsonl`
/// `Scrollpage --calibrate-pinch [--record file.jsonl]`
/// `Scrollpage --calibrate-pinch --replay file.jsonl`
///
/// Runs the camera, Vision and the real gesture engine headless (no events are
/// posted) and prints frame rate, latency, tracking quality and how far a still
/// hand would drift the pointer. Calibration walks through labelled poses and
/// reports the fingertip distances that touching and hovering produce;
/// replaying a calibration recording with `--diagnose` also shows what the
/// engine did in each pose.
enum Diagnostics {
    static func run(arguments: [String]) -> Never {
        var seconds = 10.0
        var recordPath: String?
        var replayPath: String?
        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            if a == "--record", i + 1 < arguments.count {
                recordPath = arguments[i + 1]
                i += 1
            } else if a == "--replay", i + 1 < arguments.count {
                replayPath = arguments[i + 1]
                i += 1
            } else if let s = Double(a) {
                seconds = s
            }
            i += 1
        }

        setvbuf(stdout, nil, _IOLBF, 0)
        if let replayPath { replay(replayPath) }
        print("Scrollpage diagnostics (\(Int(seconds)) s). Hold your right hand up and keep it still for a few")
        print("seconds (drift), then try pinch-move, quick pinches, fist scrolls and open-hand flicks.\n")
        withCamera {
            let pipeline = CameraPipeline()
            pipeline.updateSettings(savedSettings)
            let collector = Collector(recordPath: recordPath)
            pipeline.onFrame = { collector.add($0) }
            startCamera(pipeline) {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    pipeline.onFrame = nil
                    pipeline.videoQueue.sync { collector.printReport() }
                    exit(0)
                }
            }
        }
    }

    static func withCamera(_ start: @escaping () -> Void) -> Never {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { start() } else { deny() }
                }
            }
        default:
            deny()
        }
        dispatchMain()
    }

    static func startCamera(_ pipeline: CameraPipeline, then: @escaping () -> Void) {
        pipeline.start(deviceID: UserDefaults.standard.string(forKey: "cameraID")) { result in
            switch result {
            case .failure(let error):
                print("Camera failed: \(error.localizedDescription)")
                exit(1)
            case .success(let device):
                let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                let fps = device.activeVideoMinFrameDuration.seconds > 0 ? 1 / device.activeVideoMinFrameDuration.seconds : 0
                print("Camera: \(device.localizedName), \(d.width)x\(d.height) @ \(Int(fps.rounded())) fps")
                then()
            }
        }
    }

    private static func deny() -> Never {
        print("Camera access is denied for this process. Grant it in System Settings > Privacy & Security > Camera")
        print("(for the app that launched this command, e.g. Terminal or Cursor), or run the diagnostics from Scrollpage.app.")
        exit(2)
    }

    /// The user's saved settings, so diagnostics measure what the app would do.
    static var savedSettings: MotionSettings {
        let d = UserDefaults.standard
        var s = MotionSettings()
        if d.object(forKey: "trackingSpeed") != nil { s.trackingSpeed = d.double(forKey: "trackingSpeed") }
        if d.object(forKey: "scrollingSpeed") != nil { s.scrollingSpeed = d.double(forKey: "scrollingSpeed") }
        s.naturalScrolling = d.object(forKey: "naturalScrolling") != nil ? d.bool(forKey: "naturalScrolling") : Permissions.systemNaturalScrolling
        s.screenWidth = Double(CGDisplayBounds(CGMainDisplayID()).width)
        return s
    }

    // MARK: - Recording format

    /// One line per frame: `t`, `hands` (every hand: `chirality` "left",
    /// "right" or null, and `joints`, 21 × [x, y, confidence] or [] in the
    /// engine's frame), `selected` (index into `hands` of the hand that drove
    /// gestures, or null) and `out` (gesture outputs). Recordings from before
    /// chirality have only `joints` for the driving hand.
    static func encode(_ hand: HandSample) -> [String: Any] {
        [
            "chirality": hand.chirality?.rawValue ?? NSNull(),
            "joints": HandJoint.allCases.map { j -> [Double] in
                guard let p = hand[j] else { return [] }
                return [p.location.x, p.location.y, p.confidence]
            },
        ]
    }

    static func decodeJoints(_ joints: [[Double]], chirality: Chirality?) -> HandSample {
        var points: [HandJoint: JointPoint] = [:]
        for (j, p) in zip(HandJoint.allCases, joints) where p.count == 3 {
            points[j] = JointPoint(Vec2(p[0], p[1]), confidence: p[2])
        }
        return HandSample(points, chirality: chirality)
    }

    /// The hands of one recorded frame. A legacy frame's single hand is
    /// assumed to be the right hand, since only it was followed.
    static func decodeHands(_ object: [String: Any]) -> [HandSample] {
        if let hands = object["hands"] as? [[String: Any]] {
            return hands.compactMap { h in
                guard let joints = h["joints"] as? [[Double]] else { return nil }
                return decodeJoints(joints, chirality: (h["chirality"] as? String).flatMap(Chirality.init(rawValue:)))
            }
        }
        if let joints = object["joints"] as? [[Double]] {
            return [decodeJoints(joints, chirality: .right)]
        }
        return []
    }

    // MARK: - Replay

    /// Runs the gesture engine and the right-hand selector over a recording.
    private static func replay(_ path: String) -> Never {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("Can't read \(path)")
            exit(1)
        }
        let engine = GestureEngine(settings: savedSettings)
        var selector = HandSelector()
        let collector = Collector(recordPath: nil)
        var poses = PoseTally()
        var previousLabel: String?
        var strokeCount = 0
        for object in GuidedRecording.frames(text) {
            guard let t = object["t"] as? Double else { continue }
            let hands = decodeHands(object)
            let hand = selector.select(hands, at: t, locked: engine.isEngaged)
            let label = object["label"] as? String
            // A calibration step that toggled control off (the peace-sign step
            // does) mustn't hide what the later steps would do.
            let stepStarts = label != nil && label != "transition" && (previousLabel ?? "transition") == "transition"
            previousLabel = label
            let outputs = (stepStarts ? engine.setControl(on: true) : [])
                + (selector.isNewHand ? engine.reset() : []) + engine.process(hand, at: t)
            var stroke: StrokeReport?
            if engine.flick.strokeCount != strokeCount {
                strokeCount = engine.flick.strokeCount
                stroke = engine.flick.lastStroke
            }
            collector.add(FrameReport(time: t, hand: hand, hands: hands, outputs: outputs, snapshot: engine.snapshot,
                                      stats: PipelineStats(), stroke: stroke))
            if let label {
                poses.add(label: label, at: t, outputs: outputs, snapshot: engine.snapshot)
            }
        }
        print("Replayed \(path)")
        collector.printReport(timing: false)
        poses.printReport()
        exit(0)
    }

    /// What the engine did during each pose of a `--calibrate-pinch` recording,
    /// leaving out each step's first `Calibration.settleSeconds` while the hand
    /// gets into the pose.
    struct PoseTally {
        struct Stats {
            var frames = 0
            var pinchFrames = 0
            var scrollFrames = 0
            var offFrames = 0
            var counts: [String: Int] = [:]
            var travel = 0.0
            var scrollTravel = 0.0
        }

        private(set) var order: [String] = []
        private(set) var stats: [String: Stats] = [:]
        private var steps = Calibration.Steps()

        mutating func add(label: String, at t: Double, outputs: [GestureOutput], snapshot: GestureSnapshot) {
            guard let (pose, settled) = steps.step(label: label, at: t) else { return }
            if !order.contains(pose) { order.append(pose) }
            guard settled else { return }
            var s = stats[pose] ?? Stats()
            s.frames += 1
            if snapshot.isTouching { s.pinchFrames += 1 }
            if snapshot.isScrolling { s.scrollFrames += 1 }
            if !snapshot.controlOn { s.offFrames += 1 }
            if snapshot.toggled { s.counts["toggle", default: 0] += 1 }
            for o in outputs {
                switch o {
                case .touchBegan where snapshot.isTouching: s.counts["pinch", default: 0] += 1
                case .scrollBegan: s.counts["scroll", default: 0] += 1
                case .click(let n): s.counts["click x\(n)", default: 0] += 1
                case .pressBegan: s.counts["drag", default: 0] += 1
                case .fling: s.counts["fling", default: 0] += 1
                case let .pointerMoved(dx, dy): s.travel += (dx * dx + dy * dy).squareRoot()
                case let .scrolled(dx, dy): s.scrollTravel += (dx * dx + dy * dy).squareRoot()
                default: break
                }
            }
            stats[pose] = s
        }

        func printReport() {
            guard !order.isEmpty else { return }
            let wanted = ["touch": "pinch", "fist": "scroll", "fist-still": "scroll", "fist-roll-up": "scroll",
                          "fist-roll-down": "scroll", "fist-move": "scroll", "peace": "toggle"]
            print("\nPer pose (after the first \(fmt(Calibration.settleSeconds)) s of each step; control turned back on at each step)")
            print("  pose            want    frames  pinch held  fist held  off   begins / clicks           pointer  scroll")
            for pose in order {
                guard let s = stats[pose], s.frames > 0 else { continue }
                let n = Double(s.frames)
                let counts = s.counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                print("  " + [
                    pose.padding(toLength: 14, withPad: " ", startingAt: 0),
                    (wanted[pose] ?? "none").padding(toLength: 6, withPad: " ", startingAt: 0),
                    String(format: "%6d", s.frames),
                    String(format: "%9.0f %%", 100 * Double(s.pinchFrames) / n),
                    String(format: "%8.0f %%", 100 * Double(s.scrollFrames) / n),
                    String(format: "%3.0f %%", 100 * Double(s.offFrames) / n),
                    (counts.isEmpty ? "none" : counts).padding(toLength: 24, withPad: " ", startingAt: 0),
                    String(format: "%5.0f pt", s.travel),
                    String(format: "%5.0f pt", s.scrollTravel),
                ].joined(separator: "  "))
            }
        }
    }

    /// Only touched on the camera queue.
    final class Collector {
        private var frames = 0
        private var handFrames = 0
        private var firstTime: Double?
        private var lastTime = 0.0
        private var processing: [Double] = []
        private var latency: [Double] = []
        private var pinchRatios: [Double] = []
        private var handSizes: [Double] = []
        private var previousPalm: (p: Vec2, size: Double)?
        private var stillJitter: [Double] = []
        private var stillDrift = 0.0
        private var stillScrollDrift = 0.0
        private var stillTime = 0.0
        private var previousStillTime: Double?
        /// Palm positions (hand units) over the last 0.5 s, and whether the
        /// forearm was rolling, to find still stretches.
        private var recent: [(t: Double, p: Vec2, rolling: Bool)] = []
        private var counts: [String: Int] = [:]
        private var travel = 0.0
        private var travelX = 0.0
        private var travelY = 0.0
        private var scrollTravel = 0.0
        private var chirality: [String: Int] = [:]
        private var ignoredFrames = 0
        private var mirrored = false
        private let toggle = ToggleGestureDetector()
        private var peaceFrames = 0
        private var vFrames = 0
        private var maxToggleProgress = 0.0
        private var lastBlocked: String?
        private let recorder: FileHandle?

        init(recordPath: String?) {
            if let path = recordPath {
                FileManager.default.createFile(atPath: path, contents: nil)
                recorder = FileHandle(forWritingAtPath: path)
            } else {
                recorder = nil
            }
        }

        func add(_ r: FrameReport) {
            frames += 1
            if firstTime == nil { firstTime = r.time }
            let dt = r.time - lastTime
            lastTime = r.time
            processing.append(r.frameProcessingMs)
            latency.append(r.frameLatencyMs)
            mirrored = r.stats.imageMirrored
            for h in r.hands { chirality[h.chirality?.rawValue ?? "unknown", default: 0] += 1 }
            if r.hand == nil && !r.hands.isEmpty { ignoredFrames += 1 }

            let stamp = String(format: "%8.2f s  ", r.time - (firstTime ?? r.time))
            let m = r.snapshot.touch
            let tips = "tips " + [m.thumbIndex, m.thumbMiddle, m.indexMiddle].map { $0.map { fmt($0, 3) } ?? "–" }.joined(separator: "/")
            for output in r.outputs {
                switch output {
                case .touchBegan: print(stamp + "pinch down (\(tips))")
                case .scrollBegan: print(stamp + "fist scroll down")
                case let .click(count): print(stamp + "click ×\(count)")
                case .pressBegan: print(stamp + "press (drag)")
                case .touchEnded: print(stamp + "pinch up (\(tips))")
                case let .scrollEnded(vx, vy): print(stamp + "scroll up, glide \(fmt(Vec2(vx, vy).length, 0)) pt/s")
                default: break
                }
            }
            if let stroke = r.stroke {
                print(stamp + stroke.summary)
                counts["stroke: \(stroke.verdict.rawValue)", default: 0] += 1
            }
            if let blocked = r.snapshot.flickBlocked, blocked != lastBlocked {
                print(String(format: "%8.2f s  ", r.time - (firstTime ?? r.time)) + "fast motion, no flick: \(blocked)")
                counts["blocked: \(blocked.split(separator: "(").first!.trimmingCharacters(in: .whitespaces))", default: 0] += 1
            }
            lastBlocked = r.snapshot.flickBlocked
            for o in r.outputs {
                switch o {
                case .touchBegan: counts["touch", default: 0] += 1
                case .catchGlide: counts["catch glide", default: 0] += 1
                case .click(let n): counts["click x\(n)", default: 0] += 1
                case .pressBegan: counts["press (drag)", default: 0] += 1
                case .fling: counts["fling", default: 0] += 1
                case let .pointerMoved(dx, dy):
                    travel += (dx * dx + dy * dy).squareRoot()
                    travelX += abs(dx)
                    travelY += abs(dy)
                case .touchEnded: break
                case .scrollBegan: counts["fist scroll", default: 0] += 1
                case let .scrolled(dx, dy): scrollTravel += (dx * dx + dy * dy).squareRoot()
                case let .scrollEnded(vx, vy): if vx != 0 || vy != 0 { counts["scroll glide", default: 0] += 1 }
                }
            }
            if r.snapshot.toggled { counts[r.snapshot.controlOn ? "toggle on" : "toggle off", default: 0] += 1 }
            maxToggleProgress = max(maxToggleProgress, r.snapshot.toggleProgress)
            if let hand = r.hand, let size = r.snapshot.handSize {
                if toggle.isPeaceSign(hand, handSize: size) { peaceFrames += 1 }
                if hand.extensionReading(.index) == .extended && hand.extensionReading(.middle) == .extended
                    && hand.extensionReading(.ring) == .curled && hand.extensionReading(.little) == .curled { vFrames += 1 }
            }

            if let hand = r.hand, let palm = hand.palmCenter, let size = r.snapshot.handSize {
                handFrames += 1
                handSizes.append(size)
                if let ratio = r.snapshot.pinchRatio { pinchRatios.append(ratio) }
                recent.append((r.time, palm / size, r.snapshot.isRolling))
                while let first = recent.first, r.time - first.t > 0.5 { recent.removeFirst() }
                let still = r.time - (recent.first?.t ?? r.time) > 0.4
                    && recent.allSatisfy { $0.p.distance(to: palm / size) < 0.1 && !$0.rolling }
                if still, let prev = previousPalm {
                    stillJitter.append(palm.distance(to: prev.p) / size)
                }
                if still, let pt = previousStillTime, dt > 0, dt < 0.2 {
                    stillDrift += r.snapshot.potentialDelta.length
                    stillScrollDrift += r.snapshot.potentialScroll.length
                    stillTime += r.time - pt
                }
                previousStillTime = still ? r.time : nil
                previousPalm = (palm, size)
            } else {
                previousPalm = nil
                previousStillTime = nil
                recent.removeAll()
            }

            record(r)
        }

        private func record(_ r: FrameReport) {
            guard let recorder else { return }
            var line: [String: Any] = ["t": r.time]
            line["hands"] = r.hands.map(Diagnostics.encode)
            line["selected"] = r.hand.flatMap { h in r.hands.firstIndex(of: h) } ?? NSNull()
            line["out"] = r.outputs.map { "\($0)" }
            if let data = try? JSONSerialization.data(withJSONObject: line), let nl = "\n".data(using: .utf8) {
                recorder.write(data)
                recorder.write(nl)
            }
        }

        func printReport(timing: Bool = true) {
            let duration = max(1e-6, lastTime - (firstTime ?? lastTime))
            let th = TouchThresholds()

            print("")
            print("Frames            \(frames) in \(fmt(duration)) s = \(fmt(Double(frames) / duration)) fps")
            if timing {
                print("Processing        mean \(fmt(average(processing))) ms, p95 \(fmt(percentile(processing, 0.95))) ms (Vision + engine)")
                print("Capture→gesture   mean \(fmt(average(latency))) ms, p95 \(fmt(percentile(latency, 0.95))) ms")
            }
            print("Hand detected     \(fmt(100 * Double(handFrames) / Double(max(1, frames)), 0)) % of frames (right hand)")
            let labels = chirality.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            print("Hands seen        \(labels.isEmpty ? "none" : labels); \(ignoredFrames) frames with only ignored hands\(timing ? (mirrored ? " (mirrored frames)" : " (unmirrored frames)") : "")")
            print("Hand size         mean \(fmt(average(handSizes), 3)) image heights")
            print("Thumb–index       p5 \(fmt(percentile(pinchRatios, 0.05), 3)), median \(fmt(percentile(pinchRatios, 0.5), 3)), p95 \(fmt(percentile(pinchRatios, 0.95), 3)) hand sizes  (touch < \(fmt(th.pinchEnter, 2)), release > \(fmt(th.pinchExit, 2)))")
            print("Palm jitter       \(fmt(average(stillJitter) * 1000, 2)) mhu per frame while still")
            if stillTime > 0.5 {
                print("Still-hand drift  \(fmt(stillDrift / stillTime, 2)) pt/s if pinched, \(fmt(stillScrollDrift / stillTime, 2)) pt/s of scroll if a fist (over \(fmt(stillTime)) s of still hand; target < 1)")
            } else {
                print("Still-hand drift  – (hold the hand still for a few seconds to measure)")
            }
            let gestures = counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            print("Gestures          \(gestures.isEmpty ? "none" : gestures); pointer travel \(fmt(travel, 0)) pt (x \(fmt(travelX, 0)), y \(fmt(travelY, 0))), scroll travel \(fmt(scrollTravel, 0)) pt")
            let share = { [handFrames] (n: Int) in fmt(100 * Double(n) / Double(max(1, handFrames)), 1) }
            print("Peace sign        \(share(peaceFrames)) % of hand frames (index and middle up, ring and little curled: \(share(vFrames)) %); longest still hold \(fmt(100 * maxToggleProgress, 0)) % of a toggle")
        }
    }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let s = values.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
}

func average(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count) }

func fmt(_ v: Double, _ digits: Int = 1) -> String { v.isNaN ? "–" : String(format: "%.\(digits)f", v) }
