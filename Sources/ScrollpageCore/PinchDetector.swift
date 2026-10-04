import Foundation

/// Pinch state with hysteresis and a short debounce.
///
/// The pinch is the "finger on the trackpad": it engages below `engageRatio` and
/// only lets go above `releaseRatio`, so a pinch hovering near one threshold
/// cannot flicker. When the fingertips are occluded (common while pinching), the
/// ratio is unknown and the current state is held rather than dropped.
public struct PinchDetector: Sendable {
    public var engageRatio: Double
    public var releaseRatio: Double
    public var framesToEngage: Int
    public var framesToRelease: Int

    public private(set) var isPinching = false
    private var pending = 0

    public init(engageRatio: Double = 0.22, releaseRatio: Double = 0.38, framesToEngage: Int = 2, framesToRelease: Int = 2) {
        self.engageRatio = engageRatio
        self.releaseRatio = releaseRatio
        self.framesToEngage = framesToEngage
        self.framesToRelease = framesToRelease
    }

    public mutating func reset() {
        isPinching = false
        pending = 0
    }

    @discardableResult
    public mutating func update(_ ratio: Double?) -> Bool {
        guard let r = ratio else {
            pending = 0
            return isPinching
        }
        let wantsChange = isPinching ? r > releaseRatio : r < engageRatio
        if wantsChange {
            pending += 1
            if pending >= (isPinching ? framesToRelease : framesToEngage) {
                isPinching.toggle()
                pending = 0
            }
        } else {
            pending = 0
        }
        return isPinching
    }
}
