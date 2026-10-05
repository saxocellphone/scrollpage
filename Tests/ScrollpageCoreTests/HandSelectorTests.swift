import XCTest
@testable import ScrollpageCore

private let hu = HandPose().size

final class ChiralityTests: XCTestCase {
    /// The capture connection isn't mirrored, so Vision sees the hands as the
    /// camera does and its label is the physical hand. Were the image mirrored,
    /// the labels would swap.
    func testMirroringMapping() {
        XCTAssertEqual(Chirality.physical(visionLabel: .right, imageMirrored: false), .right)
        XCTAssertEqual(Chirality.physical(visionLabel: .left, imageMirrored: false), .left)
        XCTAssertEqual(Chirality.physical(visionLabel: .right, imageMirrored: true), .left)
        XCTAssertEqual(Chirality.physical(visionLabel: .left, imageMirrored: true), .right)
        XCTAssertNil(Chirality.physical(visionLabel: nil, imageMirrored: false))
        XCTAssertNil(Chirality.physical(visionLabel: nil, imageMirrored: true))
    }
}

final class HandSelectorTests: XCTestCase {
    private var gen = SyntheticHand(seed: 3)
    private var selector = HandSelector()
    private var t = 0.0

    private func hand(_ chirality: Chirality?, at palm: Vec2, size: Double = hu) -> HandPose {
        var pose = HandPose()
        pose.chirality = chirality
        pose.palm = palm
        pose.size = size
        return pose
    }

    @discardableResult
    private func select(_ poses: [HandPose], locked: Bool = false) -> HandPose? {
        t += 1.0 / 30
        let hands = poses.map { gen.sample($0) }
        guard let picked = selector.select(hands, at: t, locked: locked) else { return nil }
        return poses[hands.firstIndex(of: picked)!]
    }

    private let rightPalm = Vec2(1.1, 0.5)
    private let leftPalm = Vec2(0.5, 0.5)

    func testRightHandAloneIsAcquiredAfterThreeFrames() {
        let right = hand(.right, at: rightPalm)
        XCTAssertNil(select([right]))
        XCTAssertNil(select([right]))
        XCTAssertEqual(select([right])?.chirality, .right)
        for _ in 0..<30 { XCTAssertEqual(select([right])?.chirality, .right) }
    }

    func testLeftOrUnlabelledHandAloneNeverDrives() {
        for _ in 0..<60 {
            XCTAssertNil(select([hand(.left, at: leftPalm)]))
            XCTAssertNil(select([hand(nil, at: rightPalm)]))
        }
    }

    func testBothHandsPicksTheRightInEitherOrderAndSize() {
        let right = hand(.right, at: rightPalm, size: 0.12)
        let left = hand(.left, at: leftPalm, size: 0.22)
        for i in 0..<40 {
            let picked = select(i.isMultiple(of: 2) ? [left, right] : [right, left])
            if i >= 2 { XCTAssertEqual(picked, right, "frame \(i)") }
        }
    }

    func testFollowedHandIsKeptWhenALabelledRightHandAppears() {
        let first = hand(.right, at: rightPalm, size: 0.12)
        for _ in 0..<5 { select([first]) }
        let mislabelled = hand(.right, at: leftPalm, size: 0.2)
        for _ in 0..<20 { XCTAssertEqual(select([mislabelled, first]), first) }
    }

    func testLabelFlickerWithinGraceKeepsALockedGesture() {
        var right = hand(.right, at: rightPalm)
        for _ in 0..<5 { select([right]) }
        right.chirality = .left
        for i in 0..<9 {
            right.palm.x += 0.003
            XCTAssertNotNil(select([right], locked: true), "0.3 s of flicker, frame \(i)")
        }
        right.chirality = .right
        XCTAssertNotNil(select([right], locked: true))
    }

    /// While a gesture is under way the label is ignored: an edge-on hand
    /// rolling reads left for seconds at a time.
    func testSustainedFlipKeepsALockedGesture() {
        var right = hand(.right, at: rightPalm)
        for _ in 0..<5 { select([right]) }
        right.chirality = .left
        for i in 0..<90 {
            right.palm.x += 0.002
            XCTAssertNotNil(select([right], locked: true), "frame \(i)")
        }
        right.chirality = nil
        for _ in 0..<10 { XCTAssertNotNil(select([right], locked: true), "unlabelled") }
    }

    func testAHandStillFlippedWhenTheGestureEndsIsDropped() {
        var right = hand(.right, at: rightPalm)
        for _ in 0..<5 { select([right]) }
        right.chirality = .left
        for _ in 0..<30 { select([right], locked: true) }
        XCTAssertNil(select([right]), "unlocked, a left label drives nothing")
        for _ in 0..<20 { select([right]) }
        right.chirality = .right
        XCTAssertNil(select([right]), "dropped after the grace: acquired afresh")
        XCTAssertNil(select([right]))
        XCTAssertNotNil(select([right]))
    }

    /// Locked, the hand is followed by continuity: a hand of another size, or
    /// one that jumped, is not it.
    func testALockedGestureFollowsContinuityNotLabels() {
        let right = hand(.right, at: rightPalm)
        for _ in 0..<5 { select([right]) }
        let bigger = hand(.left, at: rightPalm + Vec2(0.01, 0), size: hu * 1.6)
        XCTAssertNil(select([bigger], locked: true), "too different in size")
        let far = hand(.left, at: rightPalm + Vec2(1.2 * hu, 0))
        for _ in 0..<5 { XCTAssertNil(select([far], locked: true), "moved farther than a hand can") }
    }

    func testFlickerWithoutAGestureIsIgnoredButTheHandResumesAtOnce() {
        var right = hand(.right, at: rightPalm)
        for _ in 0..<5 { select([right]) }
        right.chirality = .left
        for _ in 0..<3 { XCTAssertNil(select([right])) }
        right.chirality = .right
        XCTAssertNotNil(select([right]), "no fresh three-frame acquisition")
    }

    func testLeftHandNearbyIsNotTakenDuringAFlip() {
        let right = hand(.right, at: rightPalm)
        for _ in 0..<5 { select([right]) }
        let left = hand(.left, at: rightPalm + Vec2(-2.5 * hu, 0))
        for _ in 0..<20 { XCTAssertNil(select([left], locked: true)) }
    }

    func testRightHandFoundElsewhereIsAcquiredAtOnce() {
        let right = hand(.right, at: rightPalm)
        for _ in 0..<5 { select([right]) }
        let moved = hand(.right, at: rightPalm + Vec2(-0.4, 0.1))
        XCTAssertNil(select([moved]))
        XCTAssertNil(select([moved]))
        XCTAssertEqual(select([moved]), moved, "three frames, not the lost-hand grace first")
    }

    func testShortTrackingGapResumesAtOnce() {
        let right = hand(.right, at: rightPalm)
        for _ in 0..<5 { select([right]) }
        for _ in 0..<4 { XCTAssertNil(select([])) }
        XCTAssertNotNil(select([right]))
        for _ in 0..<15 { select([]) }
        XCTAssertNil(select([right]), "after a long gap the hand is acquired again")
    }
}

/// The right-hand rule through the whole engine.
final class RightHandOnlyTests: XCTestCase {
    private func everything(_ rig: Rig) {
        rig.hold(0.5)
        rig.pinch(true)
        rig.move(by: Vec2(0.5 * hu, 0), over: 0.4)
        rig.pinch(false)
        rig.hold(0.4)
        rig.pinch(true)
        rig.hold(0.05)
        rig.pinch(false)
        rig.hold(0.4)
        rig.fist(true)
        rig.hold(0.1)
        rig.move(by: Vec2(0, 0.5 * hu), over: 0.4)
        rig.hold(0.2)
        rig.fist(false)
        rig.hold(0.5)
        rig.move(by: Vec2(0, -0.6 * hu), over: 0.12)
        rig.hold(0.5)
        rig.peaceSign(true)
        rig.hold(1.2)
        rig.peaceSign(false)
        rig.hold(0.5)
    }

    func testLeftHandAloneDoesNothing() {
        let rig = Rig()
        rig.pose.chirality = .left
        everything(rig)
        XCTAssertTrue(rig.outputs.isEmpty, "\(rig.outputs.map(\.output))")
        XCTAssertTrue(rig.toggles.isEmpty)
    }

    func testRightHandDoesEverything() {
        let rig = Rig()
        everything(rig)
        XCTAssertEqual(rig.toggles.map(\.on), [false])
        let beforeToggle = rig.outputs.filter { $0.t < rig.toggles[0].t }
        XCTAssertEqual(beforeToggle.filter { $0.output == .touchBegan }.count, 2)
        XCTAssertEqual(rig.clicks, [1])
        XCTAssertEqual(rig.count(.scrollBegan), 1)
        XCTAssertEqual(rig.flings.count, 1)
    }

    func testLeftHandGesturingBesideTheRightIsIgnored() {
        let rig = Rig()
        var left = HandPose()
        left.chirality = .left
        left.palm = Vec2(0.3, 0.5)
        left.size = 0.22
        rig.others = [left]
        rig.hold(0.5)
        // The left hand pinches, flicks and makes a peace sign; the right rests.
        rig.run(0.3) { p, _ in rig.others[0].pinchRatio = p < 0.5 ? 0.8 : Rig.touching }
        rig.run(0.5) { p, _ in rig.others[0].palm.x = 0.3 + 0.1 * p }
        rig.run(0.3) { _, _ in rig.others[0].pinchRatio = 0.8 }
        rig.run(0.12) { p, _ in rig.others[0].palm.y = 0.5 - 0.6 * 0.22 * p }
        rig.run(1.5) { _, _ in
            rig.others[0].vAngle = 24
            rig.others[0].folded = [.ringMCP, .littleMCP]
            rig.others[0].thumbTucked = true
        }
        XCTAssertTrue(rig.outputs.isEmpty, "\(rig.outputs.map(\.output))")
        XCTAssertTrue(rig.toggles.isEmpty)

        rig.others[0] = left
        rig.pinch(true)
        rig.hold(0.05)
        rig.pinch(false)
        rig.hold(0.3)
        XCTAssertEqual(rig.clicks, [1], "the right hand still works")
    }

    func testBriefLabelFlickerDuringATapStillClicks() {
        let rig = Rig()
        rig.hold(0.5)
        rig.pinch(true)
        rig.pose.chirality = .left
        rig.hold(0.1)
        rig.pose.chirality = .right
        rig.pinch(false)
        rig.hold(0.3)
        XCTAssertEqual(rig.clicks, [1])
    }

    func testSustainedFlipKeepsADrag() {
        let rig = Rig()
        rig.hold(0.5)
        rig.pinch(true)
        rig.move(by: Vec2(0.3 * hu, 0), over: 0.3)
        rig.pose.chirality = .left
        let flippedAt = rig.t
        rig.move(by: Vec2(0.6 * hu, 0), over: 1.0)
        XCTAssertEqual(rig.count(.touchEnded), 0)
        XCTAssertGreaterThan(rig.pointerTravel(since: flippedAt).net.x, 100, "it keeps moving")
        rig.pinch(false)
        rig.hold(0.3)
        XCTAssertEqual(rig.count(.touchEnded), 1)
        XCTAssertTrue(rig.clicks.isEmpty)
        rig.pinch(true)
        rig.hold(0.05)
        rig.pinch(false)
        rig.hold(0.3)
        XCTAssertTrue(rig.clicks.isEmpty, "still labelled left: the next pinch doesn't count")
    }

    func testSustainedFlipKeepsAFistScroll() {
        let rig = Rig()
        rig.hold(0.5)
        rig.fist(true)
        rig.hold(0.1)
        rig.move(by: Vec2(0, 0.3 * hu), over: 0.3)
        rig.pose.chirality = .left
        let flippedAt = rig.t
        rig.move(by: Vec2(0, 0.6 * hu), over: 0.5)
        rig.hold(0.5)
        XCTAssertTrue(rig.scrollEnds.isEmpty)
        XCTAssertTrue(rig.engine.snapshot.isScrolling)
        XCTAssertGreaterThan(abs(rig.outputs.filter { $0.t > flippedAt }.reduce(0.0) {
            if case let .scrolled(_, dy) = $1.output { return $0 + dy }
            return $0
        }), 50)
    }
}
