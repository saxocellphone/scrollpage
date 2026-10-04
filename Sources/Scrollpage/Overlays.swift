import AppKit
import QuartzCore
import SwiftUI

/// A borderless, click-through panel that floats above everything, including
/// full-screen apps, and never takes focus.
private func makeOverlayPanel(size: NSSize) -> NSPanel {
    let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isReleasedWhenClosed = false
    return panel
}

private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

private func screenWithMouse() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
}

// MARK: - Status pill

private struct PillView: View {
    let state: PillState

    var body: some View {
        let content = HStack(spacing: 7) {
            Circle()
                .fill(Color(nsColor: state.color))
                .frame(width: 7, height: 7)
            Text(state.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)

        Group {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: .capsule)
            } else {
                content
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            }
        }
        .padding(10)
        .fixedSize()
    }
}

/// Small frosted pill at the top center of the screen. It appears when the
/// state changes and fades out two seconds later.
@MainActor
final class StatusPill {
    private let panel = makeOverlayPanel(size: NSSize(width: 240, height: 56))
    private let host = NSHostingView(rootView: PillView(state: .on))
    private var hideWork: DispatchWorkItem?

    init() {
        panel.contentView = host
        panel.alphaValue = 0
    }

    func show(_ state: PillState) {
        host.rootView = PillView(state: state)
        let size = host.fittingSize
        if let screen = screenWithMouse() {
            let visible = screen.visibleFrame
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 2,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        animate(to: 1, duration: 0.18)

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.animate(to: 0, duration: 0.35) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func animate(to alpha: CGFloat, duration: TimeInterval) {
        if reduceMotion {
            panel.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = alpha
        }
    }
}

// MARK: - Touch ring

/// A ring around the pointer while the pinch is down, so the user can see the
/// "finger" is on the pad. It fills while pressed (dragging) and pulses on click.
@MainActor
final class TouchRing {
    private let panel = makeOverlayPanel(size: NSSize(width: 48, height: 48))
    private let view = RingView(frame: NSRect(x: 0, y: 0, width: 48, height: 48))
    private var visible = false

    init() {
        panel.level = .screenSaver
        panel.contentView = view
        view.onFrame = { [weak self] in self?.follow() }
    }

    func update(touching: Bool, pressed: Bool) {
        view.setPressed(pressed)
        if touching && !visible {
            visible = true
            follow()
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            view.appear()
            view.setTracking(true)
        } else if !touching && visible {
            hide()
        }
    }

    func hide() {
        guard visible else { return }
        visible = false
        view.setTracking(false)
        panel.orderOut(nil)
    }

    func pulse() {
        if !visible {
            follow()
            panel.orderFrontRegardless()
            view.setTracking(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, !self.visible else { return }
                self.view.setTracking(false)
                self.panel.orderOut(nil)
            }
        }
        view.pulse()
    }

    private func follow() {
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2))
    }
}

private final class RingView: NSView {
    var onFrame: (() -> Void)?
    private let ring = CAShapeLayer()
    private var link: CADisplayLink?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let d: CGFloat = 34
        let rect = CGRect(x: (frame.width - d) / 2, y: (frame.height - d) / 2, width: d, height: d)
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: rect, transform: nil)
        ring.lineWidth = 2
        ring.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        ring.fillColor = NSColor.white.withAlphaComponent(0.12).cgColor
        ring.shadowColor = NSColor.black.cgColor
        ring.shadowOpacity = 0.35
        ring.shadowRadius = 3
        ring.shadowOffset = .zero
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setTracking(_ on: Bool) {
        if on, link == nil {
            let l = displayLink(target: self, selector: #selector(step))
            l.add(to: .main, forMode: .common)
            link = l
        } else if !on {
            link?.invalidate()
            link = nil
        }
    }

    @objc private func step() { onFrame?() }

    func setPressed(_ pressed: Bool) {
        let fill = NSColor.white.withAlphaComponent(pressed ? 0.45 : 0.12).cgColor
        guard ring.fillColor != fill else { return }
        ring.fillColor = fill
    }

    func appear() {
        guard !reduceMotion else { return }
        let a = CASpringAnimation(keyPath: "transform.scale")
        a.fromValue = 1.25
        a.toValue = 1
        a.damping = 18
        a.stiffness = 400
        a.duration = a.settlingDuration
        ring.add(a, forKey: "appear")
    }

    func pulse() {
        if reduceMotion {
            let a = CABasicAnimation(keyPath: "fillColor")
            a.toValue = NSColor.white.withAlphaComponent(0.5).cgColor
            a.duration = 0.12
            a.autoreverses = true
            ring.add(a, forKey: "pulse")
            return
        }
        let a = CAKeyframeAnimation(keyPath: "transform.scale")
        a.values = [1, 0.8, 1]
        a.keyTimes = [0, 0.4, 1]
        a.duration = 0.2
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        ring.add(a, forKey: "pulse")
    }
}
