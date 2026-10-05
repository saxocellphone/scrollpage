import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var onboardingWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        updateIcon()
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateIcon() }
            .store(in: &cancellables)

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: SettingsView(model: model) { [weak self] in
            self?.popover.performClose(nil)
            self?.showOnboarding()
        })

        if !model.onboarded || model.needsPermissions {
            showOnboarding()
        }
    }

    private func updateIcon() {
        let active = model.enabled && model.handVisible
        let name = model.enabled ? (active ? "hand.point.up.left.fill" : "hand.point.up.left") : "hand.raised.slash"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Scrollpage")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !model.enabled
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            PermissionCheck.current().log("menu opened")
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showOnboarding() {
        model.resetTutorial()
        model.previewOpen = true
        if onboardingWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: OnboardingView(model: model) { [weak self] in
                self?.onboardingWindow?.close()
            })
            window.center()
            onboardingWindow = window
        }
        NSApp.activate()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === onboardingWindow else { return }
        model.onboarded = true
        model.previewOpen = false
    }
}
