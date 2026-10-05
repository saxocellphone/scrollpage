import ApplicationServices
import Foundation
import Security

/// What macOS privacy checks see for this process.
///
/// TCC stores an Accessibility approval together with the app's designated
/// requirement. An ad-hoc signature's requirement is its cdhash, so every
/// rebuild is a different app to TCC: System Settings still shows the old
/// entry switched on, but `AXIsProcessTrusted()` is false and every posted
/// event is dropped.
struct PermissionCheck {
    var accessibility: Bool
    var postEvents: Bool
    var bundlePath: String
    var identifier: String?
    var cdhash: String?
    var teamID: String?
    var adHoc: Bool
    var designatedRequirement: String?

    static func current() -> PermissionCheck {
        var check = PermissionCheck(accessibility: AXIsProcessTrusted(), postEvents: CGPreflightPostEventAccess(),
                                    bundlePath: Bundle.main.bundlePath, adHoc: false)
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return check }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return check }
        var info: CFDictionary?
        if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let info = info as? [String: Any] {
            check.identifier = info[kSecCodeInfoIdentifier as String] as? String
            check.teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
            if let unique = info[kSecCodeInfoUnique as String] as? Data {
                check.cdhash = unique.map { String(format: "%02x", $0) }.joined()
            }
            let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
            check.adHoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        }
        var requirement: SecRequirement?
        if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement {
            var text: CFString?
            if SecRequirementCopyString(requirement, [], &text) == errSecSuccess { check.designatedRequirement = text as String? }
        }
        return check
    }

    var trusted: Bool { accessibility || postEvents }

    /// True when TCC approvals are pinned to this exact build.
    var approvalTiedToBuild: Bool {
        adHoc || (designatedRequirement?.hasPrefix("cdhash") ?? false)
    }

    var summary: String {
        "accessibility=\(accessibility) postEvents=\(postEvents) adHoc=\(adHoc) id=\(identifier ?? "-") "
            + "cdhash=\(cdhash ?? "-") team=\(teamID ?? "-") path=\(bundlePath)"
    }

    var report: String {
        var lines = [
            "Accessibility trusted (AXIsProcessTrusted)      \(accessibility)",
            "Event posting allowed (CGPreflightPostEventAccess) \(postEvents)",
            "Bundle      \(bundlePath)",
            "Identifier  \(identifier ?? "-")",
            "CDHash      \(cdhash ?? "-")",
            "Team ID     \(teamID ?? "-")",
            "Signature   \(adHoc ? "ad hoc" : "certificate")",
            "Designated requirement  \(designatedRequirement ?? "-")",
        ]
        if approvalTiedToBuild {
            lines.append("")
            lines.append("This build is ad hoc signed, so its Accessibility approval only matches this exact binary.")
            lines.append("Build with `make` (stable local signing identity) to keep the approval across rebuilds.")
        }
        if !trusted {
            lines.append("")
            lines.append("Not trusted: pointer, clicks and scrolling are dropped. In System Settings > Privacy & Security >")
            lines.append("Accessibility, remove Scrollpage with the minus button, then add this copy again and switch it on.")
        }
        return lines.joined(separator: "\n")
    }

    func log(_ reason: String) {
        Log.permissions.notice("\(reason, privacy: .public): \(summary, privacy: .public)")
    }

    @MainActor private static var didReset = false

    /// An entry left by a build with another signature shows as switched on in
    /// System Settings, does nothing, and stops the system prompt from adding
    /// this build. Removing Scrollpage's own entries lets the prompt start fresh.
    /// Only when `AXIsProcessTrusted()` (which follows System Settings live) is
    /// false, and once per launch, so a fresh grant is never thrown away.
    @MainActor static func resetStaleApprovalIfUntrusted() {
        guard !didReset, !AXIsProcessTrusted(), let id = Bundle.main.bundleIdentifier else { return }
        didReset = true
        for service in ["Accessibility", "PostEvent"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, id]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                Log.permissions.notice("tccutil reset \(service, privacy: .public): exit \(process.terminationStatus)")
            } catch {
                Log.permissions.error("tccutil reset \(service, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// `Scrollpage --check-permissions`. Run through LaunchServices so the app,
    /// not the shell that launched it, is the process TCC checks:
    /// `open -W -n --stdout "$(tty)" build/Scrollpage.app --args --check-permissions`
    static func runCLI() -> Never {
        let check = current()
        check.log("check-permissions")
        print(check.report)
        exit(check.trusted ? 0 : 1)
    }
}
