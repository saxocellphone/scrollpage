import AVFoundation
import ScrollpageCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    var done: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("Your hand is the trackpad")
                    .font(.system(size: 26, weight: .semibold))
                Text("Hold a hand up in front of the camera, about an arm's length away.")
                    .foregroundStyle(.secondary)
            }

            ZStack {
                CameraPreview(session: model.camera.session)
                SkeletonView(hand: model.latestHand, aspect: model.stats.aspect)
                if model.cameraStatus != .authorized || model.cameraError != nil {
                    Text(model.cameraError ?? "Camera access is needed")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 340)
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            if model.needsPermissions {
                VStack(spacing: 10) {
                    PermissionRow(title: "Camera", detail: "Scrollpage sees your hand; video never leaves this Mac",
                                  granted: model.cameraStatus == .authorized, action: model.requestCamera)
                    PermissionRow(title: "Accessibility", detail: "Lets Scrollpage move the pointer, click and scroll",
                                  granted: model.accessibilityTrusted, action: model.requestAccessibility)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
            }

            HStack(spacing: 12) {
                TutorialCard(symbol: "hand.pinch", title: "Pinch and move to point",
                             detail: "Thumb and index together, then move. Faster moves go farther.", done: model.didPoint)
                TutorialCard(symbol: "cursorarrow.click", title: "Quick pinch to click",
                             detail: "Tap thumb and index without moving. Twice to double-click.", done: model.didClick)
                TutorialCard(symbol: "hand.raised", title: "Flick an open hand to scroll",
                             detail: "A quick flick up or down glides the page. Pinch to stop it.", done: model.didScroll)
            }

            Label("To turn gestures off or back on, hold up an open hand with all five fingers spread, still, for a second.",
                  systemImage: "hand.raised.fingers.spread")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Picker("Camera", selection: Binding(get: { model.cameraID ?? "" },
                                                    set: { model.cameraID = $0.isEmpty ? nil : $0 })) {
                    Text("Automatic").tag("")
                    ForEach(model.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                .frame(maxWidth: 260)

                Spacer()

                Text(footer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 720)
        .onAppear { model.refreshCameras() }
    }

    private var footer: String {
        let s = model.stats
        guard s.fps > 0 else { return "" }
        return String(format: "%.0f fps · %.0f ms", s.fps, s.latencyMs)
    }
}

private struct TutorialCard: View {
    let symbol: String
    let title: String
    let detail: String
    let done: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(done ? Color.green : Color.accentColor)
                Spacer()
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(done ? Color.green : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            Text(title).font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(done ? Color.green.opacity(0.10) : Color.primary.opacity(0.05)))
        .animation(.easeOut(duration: 0.2), value: done)
    }
}

/// Mirrored live preview, so the user sees themselves like in a mirror.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.mirror()
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            previewLayer.videoGravity = .resizeAspect
            layer = previewLayer
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func mirror() {
            guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }

        override func layout() {
            super.layout()
            mirror()
        }
    }
}

/// Draws the tracked hand over the preview. Hand samples are already mirrored
/// and y-down in image-height units, matching the mirrored preview.
private struct SkeletonView: View {
    let hand: HandSample?
    let aspect: Double

    private static let bones: [[HandJoint]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip],
        [.indexMCP, .middleMCP, .ringMCP, .littleMCP],
    ]

    var body: some View {
        Canvas { context, size in
            guard let hand else { return }
            let scale = min(size.width / aspect, size.height)
            let origin = CGPoint(x: (size.width - aspect * scale) / 2, y: (size.height - scale) / 2)
            func point(_ j: HandJoint) -> CGPoint? {
                hand.location(j).map { CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale) }
            }

            var path = Path()
            for chain in Self.bones {
                let pts = chain.compactMap(point)
                guard pts.count > 1 else { continue }
                path.move(to: pts[0])
                for p in pts.dropFirst() { path.addLine(to: p) }
            }
            context.stroke(path, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

            let pinching = (hand.pinchRatio() ?? 1) < 0.3
            for j in HandJoint.allCases {
                guard let p = point(j) else { continue }
                let tip = j == .thumbTip || j == .indexTip
                let r: CGFloat = tip ? 5 : 3.5
                let color: Color = tip ? (pinching ? .green : .yellow) : .white
                context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
            }
        }
        .allowsHitTesting(false)
    }
}
