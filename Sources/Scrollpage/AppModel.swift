import AppKit
import AVFoundation
import Combine
import ScrollpageCore

enum PillState: Equatable {
    case on, paused, handInView, noHand, allowAccessibility, cameraUnavailable
    case scroll(String)
    case gesturesOn, gesturesOff
    /// A peace sign is being held; `turningOn` says which way it will toggle.
    case holding(progress: Double, turningOn: Bool)

    var label: String {
        switch self {
        case .on: return "On"
        case .paused: return "Paused"
        case .handInView: return "Hand in view"
        case .noHand: return "No hand"
        case .allowAccessibility: return "Allow Accessibility"
        case .cameraUnavailable: return "Camera unavailable"
        case .scroll(let arrow): return "Scroll \(arrow)"
        case .gesturesOn: return "Gestures on"
        case .gesturesOff: return "Gestures off"
        case .holding(_, let turningOn): return turningOn ? "Hold to turn on" : "Hold to turn off"
        }
    }

    var color: NSColor {
        switch self {
        case .on, .handInView, .scroll, .gesturesOn: return .systemGreen
        case .noHand, .paused, .gesturesOff: return .systemGray
        case .allowAccessibility, .cameraUnavailable: return .systemOrange
        case .holding(_, let turningOn): return turningOn ? .systemGreen : .systemGray
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    private enum Key {
        static let enabled = "enabled"
        static let trackingSpeed = "trackingSpeed"
        static let scrollingSpeed = "scrollingSpeed"
        static let naturalScrolling = "naturalScrolling"
        static let cameraID = "cameraID"
        static let onboarded = "onboarded"
    }

    /// Control: the menu switch and the peace-sign gesture both set it. Turned
    /// off by the gesture, the camera keeps watching for the peace sign to turn it
    /// back on; turned off from the menu, the camera stops.
    @Published var enabled: Bool {
        didSet {
            if !togglingByGesture { pausedByGesture = false }
            defaults.set(enabled || pausedByGesture, forKey: Key.enabled)
            camera.setControl(on: enabled)
            updateRunState()
        }
    }
    @Published private(set) var pausedByGesture = false
    @Published var trackingSpeed: Double { didSet { defaults.set(trackingSpeed, forKey: Key.trackingSpeed); pushSettings() } }
    @Published var scrollingSpeed: Double { didSet { defaults.set(scrollingSpeed, forKey: Key.scrollingSpeed); pushSettings() } }
    @Published var naturalScrolling: Bool { didSet { defaults.set(naturalScrolling, forKey: Key.naturalScrolling); pushSettings() } }
    @Published var cameraID: String? {
        didSet {
            defaults.set(cameraID, forKey: Key.cameraID)
            if cameraRunning { startCamera() }
        }
    }

    @Published private(set) var accessibilityTrusted = Permissions.accessibilityTrusted
    @Published private(set) var cameraStatus = Permissions.cameraStatus
    @Published private(set) var cameraError: String?
    @Published private(set) var cameraName: String?
    @Published private(set) var cameras: [AVCaptureDevice] = []
    @Published private(set) var handVisible = false
    @Published private(set) var stats = PipelineStats()
    @Published private(set) var latestHand: HandSample?
    /// Every hand in view, for the preview; `latestHand` is the one driving gestures.
    @Published private(set) var latestHands: [HandSample] = []

    @Published private(set) var didPoint = false
    @Published private(set) var didClick = false
    @Published private(set) var didScroll = false

    var previewOpen = false { didSet { updateRunState() } }

    var onboarded: Bool {
        get { defaults.bool(forKey: Key.onboarded) }
        set { defaults.set(newValue, forKey: Key.onboarded) }
    }

    let camera = CameraPipeline()
    let driver = InputDriver()
    let pill = StatusPill()
    let ring = TouchRing()

    private let defaults = UserDefaults.standard
    private var cameraRunning = false
    private var systemPaused = false
    private var pollTimer: Timer?
    private var pointTravel = 0.0
    private var scrollTravel = 0.0
    private var rawHandVisible = false
    private var rawHandChangedAt = 0.0
    private var basePill: PillState?
    private var togglingByGesture = false
    private var shownHoldProgress = 0.0
    private var lastUIUpdate = 0.0
    private var observers: [NSObjectProtocol] = []

    init() {
        defaults.register(defaults: [
            Key.enabled: true,
            Key.trackingSpeed: 0.5,
            Key.scrollingSpeed: 0.5,
            Key.naturalScrolling: Permissions.systemNaturalScrolling,
        ])
        enabled = defaults.bool(forKey: Key.enabled)
        trackingSpeed = defaults.double(forKey: Key.trackingSpeed)
        scrollingSpeed = defaults.double(forKey: Key.scrollingSpeed)
        naturalScrolling = defaults.bool(forKey: Key.naturalScrolling)
        cameraID = defaults.string(forKey: Key.cameraID)
        camera.setControl(on: enabled)

        // Runs on the camera queue: gestures go straight to the input driver,
        // the UI catches up on the main queue.
        let driver = self.driver
        camera.onFrame = { [weak self] report in
            driver.handle(report.outputs)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(report) }
            }
        }
        pushSettings()
        PermissionCheck.current().log("launch")
        driver.setPostingAllowed(accessibilityTrusted && enabled)
        observeSystem()
        refreshCameras()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPermissions() }
        }
        updateRunState()
        if enabled { pill.show(.on) }
    }

    var statusLine: String {
        if pausedByGesture { return "Gestures off. Hold a peace sign to turn on" }
        if !enabled { return "Paused" }
        if let cameraError { return cameraError }
        if cameraStatus == .denied || cameraStatus == .restricted { return "Camera access is off" }
        if !accessibilityTrusted { return "Needs Accessibility access to move the pointer" }
        let source = cameraName.map { " · \($0)" } ?? ""
        return (handVisible ? "Hand in view" : "Show your hand to the camera") + source
    }

    var needsPermissions: Bool {
        !accessibilityTrusted || cameraStatus == .denied || cameraStatus == .restricted || cameraStatus == .notDetermined
    }

    func resetTutorial() {
        didPoint = false
        didClick = false
        didScroll = false
        pointTravel = 0
        scrollTravel = 0
    }

    func refreshCameras() {
        cameras = CameraPipeline.availableCameras()
    }

    func requestCamera() {
        switch Permissions.cameraStatus {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async { [weak self] in
                    self?.cameraStatus = Permissions.cameraStatus
                    self?.updateRunState()
                }
            }
        case .denied, .restricted:
            Permissions.openCameraSettings()
        default:
            break
        }
    }

    func requestAccessibility() {
        PermissionCheck.resetStaleApprovalIfUntrusted()
        Permissions.promptForAccessibility()
        if !Permissions.accessibilityTrusted { Permissions.openAccessibilitySettings() }
    }

    // MARK: - Camera lifecycle

    private func updateRunState() {
        driver.setPostingAllowed(accessibilityTrusted && enabled)
        let shouldRun = (enabled || pausedByGesture || previewOpen) && !systemPaused
        if shouldRun && !cameraRunning {
            startCamera()
        } else if !shouldRun && cameraRunning {
            camera.stop()
            cameraRunning = false
            handVisible = false
            rawHandVisible = false
            latestHand = nil
            latestHands = []
            ring.hide()
        }
        refreshPill()
    }

    private func startCamera() {
        cameraStatus = Permissions.cameraStatus
        switch cameraStatus {
        case .notDetermined:
            requestCamera()
            return
        case .denied, .restricted:
            cameraError = "Camera access is off"
            refreshPill()
            return
        default:
            break
        }
        cameraRunning = true
        camera.start(deviceID: cameraID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let device):
                self.cameraError = nil
                self.cameraName = device.localizedName
            case .failure(let error):
                self.cameraError = error.localizedDescription
                self.cameraRunning = false
            }
            self.refreshPill()
        }
    }

    private func pushSettings() {
        let width = NSScreen.screens.first?.frame.width ?? 1512
        camera.updateSettings(MotionSettings(trackingSpeed: trackingSpeed, scrollingSpeed: scrollingSpeed,
                                             naturalScrolling: naturalScrolling, screenWidth: width))
    }

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        let pause: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemPaused = true
                self?.updateRunState()
            }
        }
        let resume: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemPaused = false
                self?.updateRunState()
            }
        }
        observers += [
            ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: pause),
            ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: pause),
            ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: resume),
            ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main, using: resume),
        ]
        let nc = NotificationCenter.default
        observers += [
            nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pushSettings() }
            },
            nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: camera.session, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                    self?.cameraError = error?.localizedDescription ?? "Camera unavailable"
                    self?.refreshPill()
                }
            },
            nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshCameras() }
            },
            nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshCameras()
                    if let device = note.object as? AVCaptureDevice, device.localizedName == self.cameraName, self.cameraRunning {
                        self.cameraName = nil
                        self.cameraRunning = false
                        self.updateRunState()
                    }
                }
            },
        ]
    }

    private func pollPermissions() {
        let trusted = Permissions.accessibilityTrusted
        let status = Permissions.cameraStatus
        if trusted != accessibilityTrusted {
            PermissionCheck.current().log("trust changed")
            accessibilityTrusted = trusted
            driver.setPostingAllowed(trusted && enabled)
        }
        if status != cameraStatus {
            cameraStatus = status
            if status == .authorized { cameraError = nil }
            updateRunState()
        }
        refreshPill()
    }

    // MARK: - Frames

    /// Published UI state is refreshed at most ~30 times a second unless a
    /// gesture happened.
    private func apply(_ report: FrameReport) {
        let now = CACurrentMediaTime()
        let snapshot = report.snapshot
        if snapshot.toggled {
            gestureToggled(on: snapshot.controlOn)
        } else {
            showHoldProgress(snapshot)
        }
        if enabled {
            let clicked = report.outputs.contains { if case .click = $0 { return true } else { return false } }
            ring.update(touching: snapshot.isTouching, pressed: snapshot.isPressed, clicked: clicked)
        } else {
            ring.hide()
        }

        for output in report.outputs {
            switch output {
            case let .pointerMoved(dx, dy):
                pointTravel += (dx * dx + dy * dy).squareRoot()
                if pointTravel > 250 { didPoint = true }
            case .click:
                didClick = true
            case let .fling(vx, vy):
                didScroll = true
                if enabled { pill.show(.scroll(Self.arrow(vx: vx, vy: vy))) }
            case let .scrolled(dx, dy):
                scrollTravel += (dx * dx + dy * dy).squareRoot()
                if scrollTravel > 150 { didScroll = true }
            default:
                break
            }
        }

        if snapshot.handVisible != rawHandVisible {
            rawHandVisible = snapshot.handVisible
            rawHandChangedAt = now
        }
        if handVisible != rawHandVisible && now - rawHandChangedAt > 0.4 {
            handVisible = rawHandVisible
            refreshPill()
        }

        guard report.outputs.isEmpty == false || now - lastUIUpdate > 1.0 / 30 else { return }
        lastUIUpdate = now
        if stats != report.stats { stats = report.stats }
        if previewOpen {
            latestHand = report.hand
            latestHands = report.hands
        } else if latestHand != nil || !latestHands.isEmpty {
            latestHand = nil
            latestHands = []
        }
    }

    private func gestureToggled(on: Bool) {
        shownHoldProgress = 0
        togglingByGesture = true
        pausedByGesture = !on
        enabled = on
        togglingByGesture = false
        pill.show(on ? .gesturesOn : .gesturesOff)
    }

    /// Progress appears once the peace sign has been held still briefly, and the pill
    /// fades as soon as the hold is abandoned.
    private func showHoldProgress(_ snapshot: GestureSnapshot) {
        let progress = snapshot.toggleProgress
        if progress > 0 {
            guard shownHoldProgress == 0 || abs(progress - shownHoldProgress) >= 0.02 else { return }
            shownHoldProgress = progress
            pill.show(.holding(progress: progress, turningOn: !snapshot.controlOn))
        } else if shownHoldProgress > 0 {
            shownHoldProgress = 0
            pill.hide()
        }
    }

    /// The direction the page travels through the document.
    private static func arrow(vx: Double, vy: Double) -> String {
        if abs(vy) >= abs(vx) { return vy < 0 ? "↓" : "↑" }
        return vx < 0 ? "→" : "←"
    }

    private func refreshPill() {
        let state: PillState
        if pausedByGesture {
            state = .gesturesOff
        } else if !enabled {
            state = .paused
        } else if cameraError != nil || cameraStatus == .denied || cameraStatus == .restricted {
            state = .cameraUnavailable
        } else if !accessibilityTrusted {
            state = .allowAccessibility
        } else {
            state = handVisible ? .handInView : .noHand
        }
        guard state != basePill else { return }
        let first = basePill == nil
        basePill = state
        if !first { pill.show(state) }
    }
}
