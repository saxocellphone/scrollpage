import AppKit
import ApplicationServices
import AVFoundation

enum Permissions {
    static var accessibilityTrusted: Bool {
        AXIsProcessTrusted() && CGPreflightPostEventAccess()
    }

    /// Shows the system prompt that adds Scrollpage to the Accessibility list.
    static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        _ = CGRequestPostEventAccess()
    }

    static var cameraStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openCameraSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    /// The system "Natural scrolling" setting, used as the initial default.
    static var systemNaturalScrolling: Bool {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        return (global?["com.apple.swipescrolldirection"] as? Bool) ?? true
    }
}
