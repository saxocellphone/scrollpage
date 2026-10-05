import AppKit
import QuartzCore

/// A thin ring centered on the pointer's hotspot while the pinch is down, the
/// way a system touch affordance looks: it fades in when the "finger" lands,
/// contracts briefly on click, keeps a faint fill while dragging, and fades
/// out on lift. Click-through and follows the pointer at display rate.
@MainActor
final class TouchRing {
    private static let panelSize: CGFloat = 40
    private let panel = makeOverlayPanel(size: NSSize(width: panelSize, height: panelSize))
    private let view = RingView(frame: NSRect(x: 0, y: 0, width: panelSize, height: panelSize))
    private var shown = false
    private var hideWork: DispatchWorkItem?

    init() {
        panel.level = .screenSaver
        panel.contentView = view
        view.onFrame = { [weak self] in self?.follow() }
    }

    func update(touching: Bool, pressed: Bool, clicked: Bool) {
        if touching || clicked { show() }
        view.setPressed(pressed && touching)
        if clicked { view.click() }
        if !touching && shown { hide(after: clicked ? RingView.clickDuration : 0) }
    }

    func hide() {
        guard shown else { return }
        hide(after: 0)
    }

    private func show() {
        hideWork?.cancel()
        hideWork = nil
        guard !shown else { return }
        shown = true
        follow()
        panel.orderFrontRegardless()
        view.setTracking(true)
        view.appear()
    }

    private func hide(after delay: TimeInterval) {
        shown = false
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.view.disappear {
                guard let self, !self.shown else { return }
                self.view.setTracking(false)
                self.panel.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Keeps the ring centered on the hotspot, snapped to the display's pixel
    /// grid so it never shimmers on Retina or jumps between displays.
    private func follow() {
        let mouse = NSEvent.mouseLocation
        let half = Self.panelSize / 2
        let scale = panel.backingScaleFactor
        let origin = NSPoint(x: ((mouse.x - half) * scale).rounded() / scale,
                             y: ((mouse.y - half) * scale).rounded() / scale)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
}

final class RingView: NSView {
    static let diameter: CGFloat = 22
    static let lineWidth: CGFloat = 1.5
    static let clickDuration: TimeInterval = 0.24
    static let pressedFill: CGFloat = 0.18
    static let clickFill: CGFloat = 0.20

    var onFrame: (() -> Void)?
    /// Carries opacity and the appear scale; `ring` carries the click scale.
    private let container = CALayer()
    private let ring = CAShapeLayer()
    private var link: CADisplayLink?
    private var pressed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        container.frame = bounds
        ring.frame = bounds
        let d = Self.diameter
        ring.path = CGPath(ellipseIn: CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d),
                           transform: nil)
        ring.lineWidth = Self.lineWidth
        ring.fillColor = Self.fill(0)
        ring.shadowColor = NSColor.black.cgColor
        ring.shadowOffset = .zero
        container.addSublayer(ring)
        container.opacity = 0
        layer?.addSublayer(container)
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        container.contentsScale = scale
        ring.contentsScale = scale
    }

    private static func fill(_ alpha: CGFloat) -> CGColor { NSColor.white.withAlphaComponent(alpha).cgColor }

    /// Increase Contrast swaps the translucent stroke for a solid one with a
    /// stronger shadow, so the ring still reads on any background.
    func applyStyle(increaseContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast) {
        withoutActions {
            ring.strokeColor = NSColor.white.withAlphaComponent(increaseContrast ? 1 : 0.85).cgColor
            ring.shadowOpacity = increaseContrast ? 0.7 : 0.35
            ring.shadowRadius = increaseContrast ? 2 : 3
        }
    }

    func setTracking(_ on: Bool) {
        if on, link == nil {
            let l = displayLink(target: self, selector: #selector(step))
            l.add(to: .main, forMode: .common)
            link = l
        } else if !on {
            link?.invalidate()
            link = nil
        }
    }

    @objc private func step() { onFrame?() }

    func appear() {
        applyStyle()
        let from = container.presentation()?.opacity ?? 0
        withoutActions {
            container.opacity = 1
            container.transform = CATransform3DIdentity
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = 1
        var animations: [CAAnimation] = [fade]
        if !reduceMotion {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.15
            scale.toValue = 1
            animations.append(scale)
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = 0.15
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        container.add(group, forKey: "appear")
    }

    func disappear(completion: @escaping () -> Void) {
        let from = container.presentation()?.opacity ?? container.opacity
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        withoutActions { container.opacity = 0 }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = 0
        fade.duration = 0.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        container.add(fade, forKey: "disappear")
        CATransaction.commit()
    }

    func setPressed(_ on: Bool) {
        guard on != pressed else { return }
        pressed = on
        let target = Self.fill(on ? Self.pressedFill : 0)
        let a = CABasicAnimation(keyPath: "fillColor")
        a.fromValue = ring.presentation()?.fillColor ?? ring.fillColor
        a.toValue = target
        a.duration = 0.12
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        withoutActions { ring.fillColor = target }
        ring.add(a, forKey: "pressed")
    }

    /// A short contraction with a faint fill, then back. Reduce Motion keeps
    /// only the fill.
    func click() {
        let base = pressed ? Self.pressedFill : 0
        let fill = CAKeyframeAnimation(keyPath: "fillColor")
        fill.values = [Self.fill(base), Self.fill(Self.clickFill), Self.fill(base)]
        var animations: [CAAnimation] = [fill]
        if !reduceMotion {
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [1, 0.8, 1]
            animations.append(scale)
        }
        for case let a as CAKeyframeAnimation in animations {
            a.keyTimes = [0, 0.5, 1]
            a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = Self.clickDuration
        ring.add(group, forKey: "click")
    }

    /// Sets a frozen state without animation, for rendering previews.
    func showStatic(opacity: Float, containerScale: CGFloat, ringScale: CGFloat, fill: CGFloat, increaseContrast: Bool) {
        applyStyle(increaseContrast: increaseContrast)
        withoutActions {
            container.opacity = opacity
            container.transform = CATransform3DMakeScale(containerScale, containerScale, 1)
            ring.transform = CATransform3DMakeScale(ringScale, ringScale, 1)
            ring.fillColor = Self.fill(fill)
        }
    }

    /// The layer tree, for offscreen rendering.
    var ringLayer: CALayer { container }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
