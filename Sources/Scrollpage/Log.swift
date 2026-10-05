import os

/// Read with:
/// `log show --last 10m --predicate 'subsystem == "com.saxocellphone.scrollpage"'`
/// (or `log stream` with the same predicate while gesturing).
enum Log {
    static let subsystem = "com.saxocellphone.scrollpage"
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let input = Logger(subsystem: subsystem, category: "input")
    static let gestures = Logger(subsystem: subsystem, category: "gestures")
}
