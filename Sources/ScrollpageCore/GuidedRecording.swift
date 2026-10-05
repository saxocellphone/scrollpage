import Foundation

/// A line typed into a guided recording (`--calibrate-*`, command-line tooling
/// only: the app takes no keyboard input). Enter starts the next step, `r`
/// redoes the previous one, `q` or end of input quits.
public enum GuidedCommand: Equatable, Sendable {
    case start
    case redo
    case quit

    public init(_ line: String?) {
        switch line?.trimmingCharacters(in: .whitespaces).lowercased() {
        case nil, "q": self = .quit
        case "r": self = .redo
        default: self = .start
        }
    }
}

/// Which step of a guided recording comes next, and which attempt it is.
public struct GuidedSteps: Equatable, Sendable {
    public let count: Int
    public private(set) var index = 0
    /// Attempts of each step superseded by a redo.
    public private(set) var redone: [Int]

    public init(count: Int) {
        self.count = count
        redone = Array(repeating: 0, count: count)
    }

    public var isDone: Bool { index >= count }
    /// The attempt the current step records as, from 1.
    public var attempt: Int { redone[index] + 1 }

    /// The current step was recorded.
    public mutating func advance() {
        index = min(count, index + 1)
    }

    /// Goes back to the previous step. Returns it and the attempt that is now
    /// superseded, or nil when no step has been recorded yet.
    public mutating func redo() -> (index: Int, superseded: Int)? {
        guard index > 0 else { return nil }
        index -= 1
        redone[index] += 1
        return (index, redone[index])
    }
}

public enum GuidedRecording {
    /// The frames of a recording (one JSON object per line), leaving out event
    /// lines and the frames of attempts a later redo superseded. Frames of a
    /// step stopped by quitting are kept; its `incomplete` event marks them.
    public static func frames(_ text: String) -> [[String: Any]] {
        let lines = text.split(separator: "\n").compactMap { line in
            line.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        var superseded = Set<String>()
        for line in lines where line["event"] as? String == "superseded" {
            if let label = line["label"] as? String, let attempt = line["attempt"] as? Int { superseded.insert("\(label)#\(attempt)") }
        }
        return lines.filter { line in
            guard line["event"] == nil else { return false }
            guard let label = line["label"] as? String, let attempt = line["attempt"] as? Int else { return true }
            return !superseded.contains("\(label)#\(attempt)")
        }
    }
}
