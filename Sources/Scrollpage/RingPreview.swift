import AppKit
import SwiftUI

/// Debug views of the touch ring and the status pill.
///
/// - `--render-ring out.png [hero.png [pills.png]]` draws each ring state
///   offscreen over light and dark backgrounds, with the system arrow at the
///   hotspot, and optionally the control toggle's pill states.
/// - `--ring-demo [seconds]` cycles the real ring through its states at the
///   pointer (touch, click, drag, lift).
enum RingPreview {
    private struct State {
        let label: String
        let ringScale: CGFloat
        let fill: CGFloat
        let increaseContrast: Bool
    }

    private static let states = [
        State(label: "Touch", ringScale: 1, fill: 0, increaseContrast: false),
        State(label: "Click", ringScale: 0.8, fill: RingView.clickFill, increaseContrast: false),
        State(label: "Drag", ringScale: 1, fill: RingView.pressedFill, increaseContrast: false),
        State(label: "Increase Contrast", ringScale: 1, fill: 0, increaseContrast: true),
    ]

    private static let backgrounds: [(NSColor, NSColor)] = [
        (NSColor(white: 0.96, alpha: 1), NSColor(white: 0.35, alpha: 1)),
        (NSColor(white: 0.12, alpha: 1), NSColor(white: 0.7, alpha: 1)),
    ]

    static func render(arguments: [String]) -> Never {
        MainActor.assumeIsolated {
            let sheet = arguments.first ?? "touch-ring-states.png"
            write(columns: states, to: sheet)
            if arguments.count > 1 { write(columns: [states[0]], to: arguments[1]) }
            if arguments.count > 2 { writePills(to: arguments[2]) }
        }
        exit(0)
    }

    @MainActor
    private static func writePills(to path: String) {
        let pills: [PillState] = [
            .holding(progress: 0.1, turningOn: false), .holding(progress: 0.6, turningOn: false), .gesturesOff,
            .holding(progress: 0.6, turningOn: true), .gesturesOn,
        ]
        func row(_ scheme: ColorScheme) -> some View {
            HStack(spacing: 0) {
                ForEach(pills.indices, id: \.self) { PillView(state: pills[$0], flat: true) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
            .environment(\.colorScheme, scheme)
        }
        let sheet = VStack(spacing: 0) {
            row(.light)
            row(.dark)
        }
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    }

    @MainActor
    private static func write(columns: [State], to path: String) {
        let cell = CGSize(width: 150, height: 110)
        let size = CGSize(width: cell.width * CGFloat(columns.count), height: cell.height * CGFloat(backgrounds.count))
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        if cg.ctm.a < scale { cg.scaleBy(x: scale, y: scale) }
        for (row, (background, text)) in backgrounds.enumerated() {
            for (column, state) in columns.enumerated() {
                let rect = CGRect(x: CGFloat(column) * cell.width, y: size.height - CGFloat(row + 1) * cell.height,
                                  width: cell.width, height: cell.height)
                drawCell(cg, rect: rect, background: background, text: text, state: state)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("Wrote \(path)")
        }
    }

    @MainActor
    private static func drawCell(_ cg: CGContext, rect: CGRect, background: NSColor, text: NSColor, state: State) {
        cg.setFillColor(background.cgColor)
        cg.fill(rect)
        let hotspot = CGPoint(x: rect.midX, y: rect.midY + 10)

        let view = RingView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        view.showStatic(opacity: 1, containerScale: 1, ringScale: state.ringScale, fill: state.fill,
                        increaseContrast: state.increaseContrast)
        cg.saveGState()
        cg.translateBy(x: hotspot.x - 20, y: hotspot.y - 20)
        view.ringLayer.render(in: cg)
        cg.restoreGState()

        let cursor = NSCursor.arrow
        let image = cursor.image
        image.draw(in: NSRect(x: hotspot.x - cursor.hotSpot.x, y: hotspot.y - (image.size.height - cursor.hotSpot.y),
                              width: image.size.width, height: image.size.height))

        let label = NSAttributedString(string: state.label, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: text,
        ])
        let w = label.size().width
        label.draw(at: NSPoint(x: rect.midX - w / 2, y: rect.minY + 12))
    }

    static func demo(arguments: [String]) -> Never {
        let seconds = arguments.first.flatMap(Double.init) ?? 12
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let ring = TouchRing()
            var step = 0
            print("Showing the touch ring at the pointer for \(Int(seconds)) s: touch, tap (click), drag, lift.")
            Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { _ in
                MainActor.assumeIsolated {
                    switch step % 6 {
                    case 0: ring.update(touching: true, pressed: false, clicked: false)
                    case 1: ring.update(touching: false, pressed: false, clicked: true)
                    case 2, 3: ring.update(touching: true, pressed: true, clicked: false)
                    case 4: ring.update(touching: false, pressed: false, clicked: false)
                    default: break
                    }
                    step += 1
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
            app.run()
        }
        exit(0)
    }
}
