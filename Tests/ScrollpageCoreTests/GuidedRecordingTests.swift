import XCTest
@testable import ScrollpageCore

final class GuidedRecordingTests: XCTestCase {
    func testCommands() {
        XCTAssertEqual(GuidedCommand(""), .start)
        XCTAssertEqual(GuidedCommand("   "), .start)
        XCTAssertEqual(GuidedCommand("go"), .start)
        XCTAssertEqual(GuidedCommand("r"), .redo)
        XCTAssertEqual(GuidedCommand(" R "), .redo)
        XCTAssertEqual(GuidedCommand("q"), .quit)
        XCTAssertEqual(GuidedCommand("Q"), .quit)
        XCTAssertEqual(GuidedCommand(nil), .quit, "end of input")
    }

    func testRedoStepsBackAndCountsAttempts() {
        var steps = GuidedSteps(count: 3)
        XCTAssertNil(steps.redo(), "nothing recorded yet")
        XCTAssertEqual(steps.attempt, 1)
        steps.advance()
        steps.advance()
        XCTAssertEqual(steps.index, 2)
        let first = steps.redo()
        XCTAssertEqual(first?.index, 1)
        XCTAssertEqual(first?.superseded, 1)
        XCTAssertEqual(steps.attempt, 2)
        let second = steps.redo()
        XCTAssertEqual(second?.index, 0)
        XCTAssertEqual(second?.superseded, 1)
        steps.advance()
        XCTAssertEqual(steps.redo()?.superseded, 2, "step 1 redone twice")
        XCTAssertEqual(steps.attempt, 3)
        for _ in 0..<5 { steps.advance() }
        XCTAssertTrue(steps.isDone)
        XCTAssertEqual(steps.index, 3)
    }

    func testFramesLeaveOutEventsAndSupersededAttempts() {
        let text = """
        {"t":1,"label":"transition"}
        {"t":2,"label":"open","attempt":1}
        {"t":3,"label":"touch","attempt":1}
        {"event":"superseded","label":"touch","attempt":1,"t":3.5}
        {"t":4,"label":"transition"}
        {"t":5,"label":"touch","attempt":2}
        {"t":6,"label":"hover","attempt":1}
        {"event":"incomplete","label":"hover","attempt":1,"t":6}
        not json
        {"t":7}
        """
        let times = GuidedRecording.frames(text).compactMap { $0["t"] as? Double }
        XCTAssertEqual(times, [1, 2, 4, 5, 6, 7])
    }
}
