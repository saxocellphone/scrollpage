import AVFoundation
import CoreMedia
import Foundation
import ScrollpageCore
import Vision

struct PipelineStats: Equatable {
    var fps: Double = 0
    /// Vision + engine time per frame.
    var processingMs: Double = 0
    /// Frame capture to gesture output.
    var latencyMs: Double = 0
    var width = 0
    var height = 0

    var aspect: Double { height > 0 ? Double(width) / Double(height) : 16.0 / 9.0 }
}

struct FrameReport {
    var time: Double
    var hand: HandSample?
    var outputs: [GestureOutput]
    var snapshot: GestureSnapshot
    var stats: PipelineStats
    var frameProcessingMs = 0.0
    var frameLatencyMs = 0.0
    /// A stroke the flick detector judged this frame.
    var stroke: StrokeReport?
}

/// Camera capture, Vision hand pose, and the gesture engine, all on one queue.
///
/// Late frames are dropped rather than queued (as Gstrl does), so the newest
/// frame is always the one being processed and latency cannot build up.
final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let videoQueue = DispatchQueue(label: "com.saxocellphone.scrollpage.video", qos: .userInteractive)
    /// Only touched on `videoQueue`.
    let engine = GestureEngine()

    /// Called on `videoQueue` for every processed frame.
    var onFrame: ((FrameReport) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.saxocellphone.scrollpage.session")
    private let output = AVCaptureVideoDataOutput()
    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()
    private var input: AVCaptureDeviceInput?
    private var previousPalm: Vec2?
    private var stats = PipelineStats()
    private var lastFrameTime: Double?
    private var strokeCount = 0
    private var lastBlocked: String?

    enum PipelineError: LocalizedError {
        case noCamera
        case cannotUse(String)

        var errorDescription: String? {
            switch self {
            case .noCamera: return "No camera found"
            case .cannotUse(let name): return "Can't use \(name)"
            }
        }
    }

    static func availableCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    func updateSettings(_ settings: MotionSettings) {
        videoQueue.async { self.engine.settings = settings }
    }

    /// Starts (or switches) the camera. `completion` runs on the main queue.
    func start(deviceID: String?, completion: @escaping (Result<AVCaptureDevice, Error>) -> Void) {
        sessionQueue.async {
            let result = Result { try self.configure(deviceID: deviceID) }
            if case .success(let device) = result, !self.session.isRunning {
                self.session.startRunning()
                // Starting re-applies the session preset, replacing the chosen format.
                Self.chooseFormat(for: device)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
        videoQueue.async {
            let outputs = self.engine.reset()
            self.previousPalm = nil
            self.lastFrameTime = nil
            self.onFrame?(FrameReport(time: Self.hostNow(), hand: nil, outputs: outputs,
                                      snapshot: self.engine.snapshot, stats: self.stats))
        }
    }

    private func configure(deviceID: String?) throws -> AVCaptureDevice {
        let chosen = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
            ?? AVCaptureDevice.systemPreferredCamera
            ?? AVCaptureDevice.default(for: .video)
        guard let device = chosen else { throw PipelineError.noCamera }
        if input?.device.uniqueID == device.uniqueID { return device }

        session.beginConfiguration()
        if let old = input {
            session.removeInput(old)
            input = nil
        }
        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(newInput) else { throw PipelineError.cannotUse(device.localizedName) }
            session.addInput(newInput)
            input = newInput
        } catch {
            session.commitConfiguration()
            throw error
        }
        if !session.outputs.contains(output) {
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        session.commitConfiguration()
        // The session preset is applied on commit, so the format must be chosen after it.
        Self.chooseFormat(for: device)
        return device
    }

    /// Prefers the highest frame rate (up to 60 fps), then the most pixels up to
    /// 1920 wide: frame rate drives latency and smoothness, and resolution keeps
    /// a hand far from the camera trackable. Vision costs ~10 ms even at 1080p.
    private static func chooseFormat(for device: AVCaptureDevice) {
        struct Candidate { let format: AVCaptureDevice.Format; let rate: Double; let width: Int32 }
        let candidates = device.formats.compactMap { f -> Candidate? in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard (640...1920).contains(d.width), d.width >= d.height else { return nil }
            let rate = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return Candidate(format: f, rate: rate, width: d.width)
        }
        guard let best = candidates.max(by: { a, b in
            let ra = min(a.rate.rounded(), 60), rb = min(b.rate.rounded(), 60)
            if ra != rb { return ra < rb }
            return a.width < b.width
        }) else { return }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = best.format
            if let range = best.format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                let duration = range.maxFrameRate >= 60 ? CMTime(value: 1, timescale: 60) : range.minFrameDuration
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
        } catch {
            // Keep the device's default format.
        }
    }

    static func hostNow() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let begin = Self.hostNow()
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        let hostPTS = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()).seconds
        let t = hostPTS.isFinite && hostPTS > 0 && hostPTS <= begin ? hostPTS : begin

        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let aspect = Double(width) / Double(max(1, height))

        var hands: [HandSample] = []
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:])
        if (try? handler.perform([request])) != nil {
            hands = (request.results ?? []).compactMap { Self.handSample(from: $0, aspect: aspect) }
        }
        let hand = HandSelector.select(hands, previousPalm: previousPalm)
        previousPalm = hand?.palmCenter

        let outputs = engine.process(hand, at: t)
        let end = Self.hostNow()
        let stroke = logGestures(outputs)

        if let last = lastFrameTime, t > last {
            let instant = 1 / (t - last)
            stats.fps = stats.fps == 0 ? instant : stats.fps + (instant - stats.fps) * 0.1
        }
        lastFrameTime = t
        stats.processingMs += ((end - begin) * 1000 - stats.processingMs) * 0.1
        stats.latencyMs += ((end - t) * 1000 - stats.latencyMs) * 0.1
        stats.width = width
        stats.height = height

        onFrame?(FrameReport(time: t, hand: hand, outputs: outputs, snapshot: engine.snapshot, stats: stats,
                             frameProcessingMs: (end - begin) * 1000, frameLatencyMs: (end - t) * 1000, stroke: stroke))
    }

    private func logGestures(_ outputs: [GestureOutput]) -> StrokeReport? {
        var stroke: StrokeReport?
        if engine.flick.strokeCount != strokeCount {
            strokeCount = engine.flick.strokeCount
            stroke = engine.flick.lastStroke
            if let stroke { Log.gestures.notice("\(stroke.summary, privacy: .public)") }
        }
        let blocked = engine.snapshot.flickBlocked
        if let blocked, blocked != lastBlocked {
            Log.gestures.notice("fast motion, no flick: \(blocked, privacy: .public)")
        }
        lastBlocked = blocked
        for output in outputs {
            switch output {
            case let .fling(vx, vy):
                Log.gestures.notice("fling emitted vx=\(vx, format: .fixed(precision: 0)) vy=\(vy, format: .fixed(precision: 0))")
            case .touchBegan:
                Log.gestures.notice("touch began, pinch ratio \(self.engine.snapshot.pinchRatio ?? -1, format: .fixed(precision: 2))")
            case .touchEnded, .click, .pressBegan:
                Log.gestures.notice("\(String(describing: output), privacy: .public)")
            case .pointerMoved:
                break
            }
        }
        return stroke
    }

    private static let jointNames: [(VNHumanHandPoseObservation.JointName, HandJoint)] = [
        (.wrist, .wrist),
        (.thumbCMC, .thumbCMC), (.thumbMP, .thumbMP), (.thumbIP, .thumbIP), (.thumbTip, .thumbTip),
        (.indexMCP, .indexMCP), (.indexPIP, .indexPIP), (.indexDIP, .indexDIP), (.indexTip, .indexTip),
        (.middleMCP, .middleMCP), (.middlePIP, .middlePIP), (.middleDIP, .middleDIP), (.middleTip, .middleTip),
        (.ringMCP, .ringMCP), (.ringPIP, .ringPIP), (.ringDIP, .ringDIP), (.ringTip, .ringTip),
        (.littleMCP, .littleMCP), (.littlePIP, .littlePIP), (.littleDIP, .littleDIP), (.littleTip, .littleTip),
    ]

    /// Vision points are normalized with a bottom-left origin. Convert to the
    /// engine's mirrored, y-down frame measured in image heights.
    static func handSample(from observation: VNHumanHandPoseObservation, aspect: Double) -> HandSample? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        var joints: [HandJoint: JointPoint] = [:]
        for (name, joint) in jointNames {
            guard let p = points[name], p.confidence > 0 else { continue }
            joints[joint] = JointPoint(Vec2((1 - p.location.x) * aspect, 1 - p.location.y), confidence: Double(p.confidence))
        }
        return joints.isEmpty ? nil : HandSample(joints)
    }
}
