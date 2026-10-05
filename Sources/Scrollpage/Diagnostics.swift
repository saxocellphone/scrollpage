import AVFoundation
import Foundation
import ScrollpageCore

/// `Scrollpage --diagnose [seconds] [--record file.jsonl]`
///
/// Runs the camera, Vision and the real gesture engine headless (no events are
/// posted) and prints frame rate, latency, tracking quality and how far a still
/// hand would drift the pointer.
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
        print("Scrollpage diagnostics (\(Int(seconds)) s). Hold a hand up and keep it still for a few")
        print("seconds (drift), then try pinch-move, quick pinches and open-hand flicks.\n")

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            start(seconds: seconds, recordPath: recordPath)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { start(seconds: seconds, recordPath: recordPath) } else { deny() }
                }
            }
        default:
            deny()
        }
        dispatchMain()
    }

    private static func deny() -> Never {
        print("Camera access is denied for this process. Grant it in System Settings > Privacy & Security > Camera")
        print("(for the app that launched this command, e.g. Terminal or Cursor), or run the diagnostics from Scrollpage.app.")
        exit(2)
    }

    /// The user's saved settings, so diagnostics measure what the app would do.
    private static var savedSettings: MotionSettings {
        let d = UserDefaults.standard
        var s = MotionSettings()
        if d.object(forKey: "trackingSpeed") != nil { s.trackingSpeed = d.double(forKey: "trackingSpeed") }
        if d.object(forKey: "scrollingSpeed") != nil { s.scrollingSpeed = d.double(forKey: "scrollingSpeed") }
        s.naturalScrolling = d.object(forKey: "naturalScrolling") != nil ? d.bool(forKey: "naturalScrolling") : Permissions.systemNaturalScrolling
        s.screenWidth = Double(CGDisplayBounds(CGMainDisplayID()).width)
        return s
    }

    /// Runs the gesture engine over a recording made with `--record`.
    private static func replay(_ path: String) -> Never {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("Can't read \(path)")
            exit(1)
        }
        let engine = GestureEngine(settings: savedSettings)
        let collector = Collector(recordPath: nil)
        var previousPalm: Vec2?
        var strokeCount = 0
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = object["t"] as? Double else { continue }
            var hand: HandSample?
            if let joints = object["joints"] as? [[Double]] {
                var points: [HandJoint: JointPoint] = [:]
                for (j, p) in zip(HandJoint.allCases, joints) where p.count == 3 {
                    points[j] = JointPoint(Vec2(p[0], p[1]), confidence: p[2])
                }
                hand = HandSelector.select([HandSample(points)], previousPalm: previousPalm)
            }
            previousPalm = hand?.palmCenter
            let outputs = engine.process(hand, at: t)
            var stroke: StrokeReport?
            if engine.flick.strokeCount != strokeCount {
                strokeCount = engine.flick.strokeCount
                stroke = engine.flick.lastStroke
            }
            collector.add(FrameReport(time: t, hand: hand, outputs: outputs, snapshot: engine.snapshot,
                                      stats: PipelineStats(), stroke: stroke))
        }
        print("Replayed \(path)")
        collector.printReport(timing: false)
        exit(0)
    }

    private static func start(seconds: Double, recordPath: String?) {
        let pipeline = CameraPipeline()
        pipeline.updateSettings(savedSettings)
        let collector = Collector(recordPath: recordPath)
        pipeline.onFrame = { collector.add($0) }
        pipeline.start(deviceID: nil) { result in
            switch result {
            case .failure(let error):
                print("Camera failed: \(error.localizedDescription)")
                exit(1)
            case .success(let device):
                let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                let fps = device.activeVideoMinFrameDuration.seconds > 0 ? 1 / device.activeVideoMinFrameDuration.seconds : 0
                print("Camera: \(device.localizedName), \(d.width)x\(d.height) @ \(Int(fps.rounded())) fps")
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    pipeline.onFrame = nil
                    pipeline.videoQueue.sync { collector.printReport() }
                    exit(0)
                }
            }
        }
    }

    /// Only touched on the camera queue.
    private final class Collector {
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
        private var stillTime = 0.0
        private var previousStillTime: Double?
        /// Palm positions (hand units) over the last 0.5 s, to find still stretches.
        private var recent: [(t: Double, p: Vec2)] = []
        private var counts: [String: Int] = [:]
        private var travel = 0.0
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

            if let stroke = r.stroke {
                print(String(format: "%8.2f s  ", r.time - (firstTime ?? r.time)) + stroke.summary)
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
                case let .pointerMoved(dx, dy): travel += (dx * dx + dy * dy).squareRoot()
                case .touchEnded: break
                }
            }

            if let hand = r.hand, let palm = hand.palmCenter, let size = r.snapshot.handSize {
                handFrames += 1
                handSizes.append(size)
                if let ratio = r.snapshot.pinchRatio { pinchRatios.append(ratio) }
                recent.append((r.time, palm / size))
                while let first = recent.first, r.time - first.t > 0.5 { recent.removeFirst() }
                let still = r.time - (recent.first?.t ?? r.time) > 0.4
                    && recent.allSatisfy { $0.p.distance(to: palm / size) < 0.1 }
                if still, let prev = previousPalm {
                    stillJitter.append(palm.distance(to: prev.p) / size)
                }
                if still, let pt = previousStillTime, dt > 0, dt < 0.2 {
                    stillDrift += r.snapshot.potentialDelta.length
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
            if let hand = r.hand {
                line["joints"] = HandJoint.allCases.map { j -> [Double] in
                    guard let p = hand[j] else { return [] }
                    return [p.location.x, p.location.y, p.confidence]
                }
            } else {
                line["joints"] = NSNull()
            }
            line["out"] = r.outputs.map { "\($0)" }
            if let data = try? JSONSerialization.data(withJSONObject: line), let nl = "\n".data(using: .utf8) {
                recorder.write(data)
                recorder.write(nl)
            }
        }

        func printReport(timing: Bool = true) {
            let duration = max(1e-6, lastTime - (firstTime ?? lastTime))
            func pct(_ values: [Double], _ p: Double) -> Double {
                guard !values.isEmpty else { return .nan }
                let s = values.sorted()
                return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
            }
            func mean(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count) }
            func f(_ v: Double, _ digits: Int = 1) -> String { v.isNaN ? "–" : String(format: "%.\(digits)f", v) }

            print("")
            print("Frames            \(frames) in \(f(duration)) s = \(f(Double(frames) / duration)) fps")
            if timing {
                print("Processing        mean \(f(mean(processing))) ms, p95 \(f(pct(processing, 0.95))) ms (Vision + engine)")
                print("Capture→gesture   mean \(f(mean(latency))) ms, p95 \(f(pct(latency, 0.95))) ms")
            }
            print("Hand detected     \(f(100 * Double(handFrames) / Double(max(1, frames)), 0)) % of frames")
            print("Hand size         mean \(f(mean(handSizes), 3)) image heights")
            print("Pinch ratio       min \(f(pct(pinchRatios, 0), 2)), median \(f(pct(pinchRatios, 0.5), 2)), max \(f(pct(pinchRatios, 1), 2))  (engage < 0.22, release > 0.38)")
            print("Palm jitter       \(f(mean(stillJitter) * 1000, 2)) mhu per frame while still")
            if stillTime > 0.5 {
                print("Still-hand drift  \(f(stillDrift / stillTime, 2)) pt/s if pinched (over \(f(stillTime)) s of still hand; target < 1)")
            } else {
                print("Still-hand drift  – (hold the hand still for a few seconds to measure)")
            }
            let gestures = counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            print("Gestures          \(gestures.isEmpty ? "none" : gestures); pointer travel \(f(travel, 0)) pt")
        }
    }
}
