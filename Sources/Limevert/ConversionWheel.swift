import AppKit
import QuartzCore
import SwiftUI

enum Brand {
    static let lime = NSColor(srgbRed: 0.62, green: 0.84, blue: 0.24, alpha: 1)
    static let limeDeep = NSColor(srgbRed: 0.33, green: 0.62, blue: 0.10, alpha: 1)
}

/// Radial wheel shown under the cursor during a file drag. Each petal is a drop target.
@MainActor
final class ConversionWheelController {
    static let shared = ConversionWheelController()
    private var panel: NSPanel?
    private var watchdog: Timer?

    func show(for urls: [URL], at point: NSPoint) {
        close()
        let actions = ActionCatalog.actions(for: urls)
        guard !actions.isEmpty else { return }
        let view = WheelView(urls: urls, actions: actions)
        let size = view.diameter
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        let frame = WheelPlacement.frame(around: point, panelSize: size, visibleRadius: view.visibleRadius,
                                         in: screen?.visibleFrame ?? NSRect(origin: .zero, size: CGSize(width: size, height: size)))
        var content: NSView = view
        if #available(macOS 26, *), Theme.glassEnabled {
            // System Liquid Glass renders below; the AppKit view stays on top as the invisible drop target.
            view.drawsWheel = false
            let glass = PassthroughHostingView(rootView: GlassWheelView(model: view.model, style: Settings.shared.glassStyle))
            let stack = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
            for v in [glass, view] as [NSView] {
                v.frame = stack.bounds
                v.autoresizingMask = [.width, .height]
                stack.addSubview(v)
            }
            content = stack
        }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = content
        view.onFinish = { [weak self] in self?.close() }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        view.wantsLayer = true
        if view.drawsWheel, let layer = view.layer {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.86
            grow.toValue = 1
            grow.duration = 0.18
            grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.3, 0.4, 1)
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            layer.add(grow, forKey: "grow")
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        self.panel = panel
        Feedback.pop()

        // Dismiss once the drag ends anywhere else.
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self?.watchdog?.invalidate()
                // Leave a moment for performDragOperation to run first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.close() }
            }
        }
    }

    func close() {
        watchdog?.invalidate()
        watchdog = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Where the wheel's panel goes: centered on the pointer when it fits, otherwise slid inward
/// just far enough that the whole wheel is inside `area` (a screen's visible frame, clear of the menu bar and Dock).
enum WheelPlacement {
    static let margin: CGFloat = 8

    static func frame(around point: NSPoint, panelSize: CGFloat, visibleRadius: CGFloat, in area: NSRect) -> NSRect {
        func axis(_ p: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            let minC = lo + visibleRadius + margin, maxC = hi - visibleRadius - margin
            // Screen smaller than the wheel on this axis: center it.
            guard minC <= maxC else { return (lo + hi) / 2 }
            return min(max(p, minC), maxC)
        }
        let c = NSPoint(x: axis(point.x, area.minX, area.maxX), y: axis(point.y, area.minY, area.maxY))
        return NSRect(x: c.x - panelSize / 2, y: c.y - panelSize / 2, width: panelSize, height: panelSize)
    }
}

final class WheelView: NSView {
    struct Petal {
        let action: WheelAction
        let ring: Int
        let start: CGFloat   // radians
        let end: CGFloat
    }

    let urls: [URL]
    private var petals: [Petal] = []
    private var hovered: Int? {
        didSet { model.hovered = hovered }
    }
    var onFinish: () -> Void = {}
    /// False when the SwiftUI glass wheel renders the visuals underneath.
    var drawsWheel = true
    private(set) var model: WheelModel!

    private let hub: CGFloat = 58
    private let ringWidth: CGFloat = 78
    private let gap: CGFloat = 4
    private let edgeSlack: CGFloat = 20
    private let rings: Int
    var diameter: CGFloat { 2 * (hub + CGFloat(rings) * (ringWidth + gap)) + 48 }
    /// Radius of everything that must stay on screen: the outer ring plus its drop-target slack and pop-out.
    var visibleRadius: CGFloat { radii(rings - 1).1 + edgeSlack }

    init(urls: [URL], actions: [WheelAction]) {
        self.urls = urls
        let conversions = actions.filter { if case .convert = $0 { true } else { false } }
        let tools = actions.filter { if case .tool = $0 { true } else { false } }
        // Conversions on the inner ring, tools on the outer one; a single long list is split in two.
        let editors = tools.filter { if case .tool(let t) = $0 { t.opensEditor } else { false } }
        let layout: [[WheelAction]]
        // Editors get a third ring when there are enough of them, so labels stay readable.
        if !conversions.isEmpty && editors.count >= 3 {
            layout = [conversions, tools.filter { !editors.contains($0) }, editors]
        } else if !conversions.isEmpty && !tools.isEmpty { layout = [conversions, tools] }
        else if actions.count > 12 { layout = [Array(actions.prefix(8)), Array(actions.dropFirst(8))] }
        else { layout = [actions] }
        rings = layout.count
        super.init(frame: .zero)
        for (ring, items) in layout.enumerated() {
            let step = 2 * CGFloat.pi / CGFloat(items.count)
            for (i, action) in items.enumerated() {
                // Start at 12 o'clock and go clockwise.
                let end = CGFloat.pi / 2 - CGFloat(i) * step
                petals.append(Petal(action: action, ring: ring, start: end - step, end: end))
            }
        }
        setFrameSize(NSSize(width: diameter, height: diameter))
        model = WheelModel(urls: urls, petals: petals.map { p in
            let (r0, r1) = radii(p.ring)
            return PetalGeometry(action: p.action, inner: r0, outer: r1, start: p.start, end: p.end)
        }, hub: hub, diameter: diameter)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    private func radii(_ ring: Int) -> (CGFloat, CGFloat) {
        let inner = hub + gap + CGFloat(ring) * (ringWidth + gap)
        return (inner, inner + ringWidth)
    }

    private func path(for p: Petal, grow: CGFloat = 0) -> NSBezierPath {
        var (r0, r1) = radii(p.ring)
        r0 -= grow / 2
        r1 += grow
        let inset: CGFloat = 0.012
        let path = NSBezierPath()
        let a0 = (p.start + inset) * 180 / .pi, a1 = (p.end - inset) * 180 / .pi
        path.appendArc(withCenter: center, radius: r1, startAngle: a0, endAngle: a1, clockwise: false)
        path.appendArc(withCenter: center, radius: r0, startAngle: a1, endAngle: a0, clockwise: true)
        path.close()
        return path
    }

    private func petalIndex(at point: NSPoint) -> Int? {
        let dx = point.x - center.x, dy = point.y - center.y
        let r = hypot(dx, dy)
        for (i, p) in petals.enumerated() {
            let (r0, r1) = radii(p.ring)
            // The outermost ring reaches to the panel edge so a slightly wide drop still counts.
            let reach = p.ring == rings - 1 ? edgeSlack : gap
            guard r >= r0 - gap, r <= r1 + reach else { continue }
            // Normalize the angle into [start, start + 2π).
            var angle = atan2(dy, dx)
            while angle < p.start { angle += 2 * .pi }
            while angle >= p.start + 2 * .pi { angle -= 2 * .pi }
            if angle <= p.end { return i }
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard drawsWheel else {
            // The window server lets drags fall through fully transparent pixels, and system glass
            // isn't part of our window's pixels. A barely-visible fill keeps the whole wheel a drop target.
            let r = radii(rings - 1).1 + edgeSlack
            NSColor(white: 0, alpha: 0.012).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)).fill()
            return
        }
        let outer = radii(rings - 1).1 + 6
        let disk = NSBezierPath(ovalIn: NSRect(x: center.x - outer, y: center.y - outer, width: 2 * outer, height: 2 * outer))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.set()
        NSColor(white: 0.07, alpha: 0.88).setFill()
        disk.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 1, alpha: 0.14).setStroke()
        disk.lineWidth = 1
        disk.stroke()

        // Draw the hovered petal last so its pop-out sits above its neighbours.
        let order = petals.indices.filter { $0 != hovered } + (hovered.map { [$0] } ?? [])
        for i in order {
            let p = petals[i]
            let isHover = i == hovered
            let base: NSColor
            if case .convert = p.action { base = Brand.lime.withAlphaComponent(0.20) } else { base = NSColor(white: 1, alpha: 0.08) }
            let shape = path(for: p, grow: isHover ? 6 : 0)
            if isHover {
                NSGradient(starting: Brand.lime, ending: Brand.lime.blended(withFraction: 0.25, of: Brand.limeDeep) ?? Brand.lime)?
                    .draw(in: shape, relativeCenterPosition: .zero)
            } else {
                base.setFill()
                shape.fill()
            }
            (isHover ? NSColor.white.withAlphaComponent(0.5) : NSColor(white: 1, alpha: 0.07)).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            drawLabel(for: p, highlighted: isHover)
        }

        let hubPath = NSBezierPath(ovalIn: NSRect(x: center.x - hub, y: center.y - hub, width: 2 * hub, height: 2 * hub))
        NSGradient(starting: Brand.lime, ending: Brand.limeDeep)?.draw(in: hubPath, angle: -90)
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let rim = NSBezierPath(ovalIn: NSRect(x: center.x - hub + 1.5, y: center.y - hub + 1.5, width: 2 * hub - 3, height: 2 * hub - 3))
        rim.lineWidth = 1
        rim.stroke()
        let title: String, subtitle: String
        if let h = hovered {
            title = petals[h].action.label
            subtitle = urls.count == 1 ? "Drop to apply" : "Drop \(urls.count) files"
        } else {
            title = urls.count == 1 ? urls[0].pathExtension.uppercased().nilIfEmpty ?? "Item" : "\(urls.count) items"
            subtitle = "Drop on a petal"
        }
        drawCentered(title, font: .systemFont(ofSize: 15, weight: .bold), color: .black.withAlphaComponent(0.85),
                     at: CGPoint(x: center.x, y: center.y + 8), maxWidth: 2 * hub - 14)
        drawCentered(subtitle, font: .systemFont(ofSize: 10, weight: .medium), color: .black.withAlphaComponent(0.6),
                     at: CGPoint(x: center.x, y: center.y - 12), maxWidth: 2 * hub - 14)
    }

    private func drawLabel(for p: Petal, highlighted: Bool) {
        let (r0, r1) = radii(p.ring)
        let mid = (p.start + p.end) / 2, r = (r0 + r1) / 2
        let pt = CGPoint(x: center.x + cos(mid) * r, y: center.y + sin(mid) * r)
        let color: NSColor = highlighted ? NSColor(white: 0.05, alpha: 1) : NSColor(white: 1, alpha: 0.92)
        let maxWidth = min(ringWidth - 8, (p.end - p.start) * r - 6)
        if let symbol = p.action.symbol,
           let img = NSImage(systemSymbolName: symbol, accessibilityDescription: p.action.label)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)) {
            let tinted = img.tinted(color)
            let s = tinted.size
            tinted.draw(in: NSRect(x: pt.x - s.width / 2, y: pt.y + 1, width: s.width, height: s.height))
            drawCentered(p.action.label, font: .systemFont(ofSize: 9, weight: .semibold), color: color,
                         at: CGPoint(x: pt.x, y: pt.y - 9), maxWidth: maxWidth)
        } else {
            drawCentered(p.action.label, font: .systemFont(ofSize: 13, weight: .bold), color: color,
                         at: pt, maxWidth: maxWidth)
        }
    }

    private func drawCentered(_ text: String, font: NSFont, color: NSColor, at pt: CGPoint, maxWidth: CGFloat) {
        var font = font
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var size = (text as NSString).size(withAttributes: attrs)
        while size.width > maxWidth && font.pointSize > 7 {
            font = NSFont.systemFont(ofSize: font.pointSize - 0.5, weight: .semibold)
            attrs[.font] = font
            size = (text as NSString).size(withAttributes: attrs)
        }
        (text as NSString).draw(at: CGPoint(x: pt.x - size.width / 2, y: pt.y - size.height / 2), withAttributes: attrs)
    }

    // MARK: Dragging destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let idx = petalIndex(at: convert(sender.draggingLocation, from: nil))
        if idx != hovered {
            hovered = idx
            if idx != nil { MainActor.assumeIsolated { Feedback.tick() } }
            needsDisplay = true
        }
        return idx == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hovered = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let idx = petalIndex(at: convert(sender.draggingLocation, from: nil)) else { return false }
        let dropped = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let targets = dropped.isEmpty ? urls : dropped
        let action = petals[idx].action
        let finish = onFinish
        DispatchQueue.main.async {
            finish()
            ActionRunner.run(action, on: targets)
        }
        return true
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        draw(in: NSRect(origin: .zero, size: size))
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        img.unlockFocus()
        return img
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
