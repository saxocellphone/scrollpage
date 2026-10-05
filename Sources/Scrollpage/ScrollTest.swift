import CoreGraphics
import Foundation
import ScrollpageCore

/// `Scrollpage --test-scroll [vy] [--vx vx] [--at x,y]`
///
/// Posts one synthetic fling through the real `InputDriver`, exactly as a
/// detected flick would, at the pointer (or after moving it to `x,y`, global
/// top-left coordinates). `vy` is content velocity in points per second,
/// y-down: positive moves the content down (towards the top of a document).
/// Launch it through `open` to test the app's own Accessibility approval.
enum ScrollTest {
    static func run(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        var vx = 0.0, vy = -2000.0
        var at: CGPoint?
        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            if a == "--vx", i + 1 < arguments.count, let v = Double(arguments[i + 1]) {
                vx = v
                i += 1
            } else if a == "--at", i + 1 < arguments.count {
                let parts = arguments[i + 1].split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 { at = CGPoint(x: parts[0], y: parts[1]) }
                i += 1
            } else if let v = Double(a) {
                vy = v
            }
            i += 1
        }

        let check = PermissionCheck.current()
        check.log("test-scroll")
        print(check.report)
        print("")
        if !check.trusted { print("Warning: not trusted, so the window server will drop these events.\n") }

        if let at {
            CGWarpMouseCursorPosition(at)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        let driver = InputDriver()
        driver.setPostingAllowed(true)
        let start = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            print("Posting fling vx=\(vx) vy=\(vy) pt/s at \(CGEvent(source: nil)?.location ?? .zero)")
            driver.handle([.fling(vx: vx, vy: vy)])
        }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            let stats = driver.scrollStats
            guard stats.momentumEnded || Date().timeIntervalSince(start) > 5 else { return }
            timer.invalidate()
            print("Posted \(stats.events) scroll events (\(stats.momentumEvents) momentum), "
                + "total wheel1 \(stats.wheel1) px, wheel2 \(stats.wheel2) px")
            print("Expected glide ≈ \(Int((Vec2(vx, vy).length * MomentumScroller().timeConstant).rounded())) px")
            exit(stats.events > 0 ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }
}
