import AppKit
import QuartzCore
import SwiftUI

/// A borderless, click-through panel that floats above everything, including
/// full-screen apps, and never takes focus.
func makeOverlayPanel(size: NSSize) -> NSPanel {
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

var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

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

