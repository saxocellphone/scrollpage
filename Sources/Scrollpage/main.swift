import AppKit

let arguments = CommandLine.arguments

if let index = arguments.firstIndex(of: "--diagnose") {
    Diagnostics.run(arguments: Array(arguments[(index + 1)...]))
}
if arguments.contains("--check-permissions") {
    PermissionCheck.runCLI()
}
if let index = arguments.firstIndex(of: "--test-scroll") {
    ScrollTest.run(arguments: Array(arguments[(index + 1)...]))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
