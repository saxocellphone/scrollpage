import Foundation

/// `Scrollpage --calibrate-fist [--record file.jsonl]`
///
/// A guided recording of the fist that scrolls: held still, rolled palm up and
/// palm down, moved up and down; near misses (a relaxed open hand, a loose
/// curl); and the thumb-to-little pinch as the fallback candidate.
enum FistCalibration {
    static let steps = [
        Calibration.Step(label: "fist-still", prompt: "RIGHT hand, edge-on as you naturally hold it: make a FIST and hold still.", seconds: 4),
        Calibration.Step(label: "fist-roll-up", prompt: "Fist: roll the forearm so the palm turns UP toward the ceiling, and back. 2–3 times, slowly.", seconds: 7),
        Calibration.Step(label: "fist-roll-down", prompt: "Fist: roll the forearm so the palm turns DOWN toward the floor, and back. 2–3 times, slowly.", seconds: 7),
        Calibration.Step(label: "fist-move", prompt: "Fist, no rolling: move the whole hand slowly UP and DOWN.", seconds: 6),
        Calibration.Step(label: "relaxed", prompt: "Near miss: relaxed OPEN hand at rest, fingers loose. Hold.", seconds: 4),
        Calibration.Step(label: "loose-curl", prompt: "Near miss: LOOSELY curled, half-closed hand (not a fist). Hold.", seconds: 4),
        Calibration.Step(label: "little-touch", prompt: "Fallback: touch THUMB tip to LITTLE fingertip and hold still.", seconds: 4),
        Calibration.Step(label: "little-taps", prompt: "Fallback: a few quick thumb-to-LITTLE taps (touch and let go).", seconds: 6),
    ]

    static func run(arguments: [String]) -> Never {
        var recordPath = "/tmp/scrollpage-fist-\(Int(Date().timeIntervalSince1970)).jsonl"
        if let i = arguments.firstIndex(of: "--record"), i + 1 < arguments.count { recordPath = arguments[i + 1] }
        GuidedRecorder.run(title: "Scrollpage fist calibration. RIGHT hand, natural edge-on pose.", steps: steps, recordPath: recordPath)
    }
}
