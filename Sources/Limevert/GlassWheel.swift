import AppKit
import SwiftUI

/// Glass style for the wheel on macOS 26 and later.
enum WheelGlass: String, CaseIterable, Identifiable {
    case regular, clear
    var id: String { rawValue }
    var label: String { self == .regular ? "Regular" : "Clear" }
}

/// Petal geometry shared by the AppKit drop target and the SwiftUI glass renderer.
/// Angles are in radians, counter-clockwise from 3 o'clock (AppKit's y-up convention).
struct PetalGeometry {
    let action: WheelAction
    let inner: CGFloat
    let outer: CGFloat
    let start: CGFloat
    let end: CGFloat
    var isConversion: Bool { if case .convert = action { true } else { false } }
}

final class WheelModel: ObservableObject {
    let urls: [URL]
    let petals: [PetalGeometry]
    let hub: CGFloat
    let diameter: CGFloat
    @Published var hovered: Int?
    @Published var appeared = false

    init(urls: [URL], petals: [PetalGeometry], hub: CGFloat, diameter: CGFloat) {
        self.urls = urls
        self.petals = petals
        self.hub = hub
        self.diameter = diameter
    }

    var title: String {
        if let h = hovered { return petals[h].action.label }
        return urls.count == 1 ? urls[0].pathExtension.uppercased().nilIfEmpty ?? "Item" : "\(urls.count) items"
    }
    var subtitle: String {
        if hovered != nil { return urls.count == 1 ? "Drop to apply" : "Drop \(urls.count) files" }
        return "Drop on a petal"
    }
}

/// Ring segment centred in its rect. `grow` pushes the outer edge out (and the inner edge in, by half).
struct AnnularSector: Shape {
    var inner: CGFloat
    var outer: CGFloat
    var start: CGFloat
    var end: CGFloat
    var gap: CGFloat = 0.018
    var grow: CGFloat = 0

    var animatableData: CGFloat {
        get { grow }
        set { grow = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r0 = inner - grow / 2, r1 = outer + grow
        let a0 = start + gap, a1 = end - gap
        // SwiftUI is y-down, so flip the sine to keep AppKit's angle convention.
        func pt(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: c.x + cos(a) * r, y: c.y - sin(a) * r) }
        let steps = max(8, Int((a1 - a0) * 40))
        var p = Path()
        p.move(to: pt(r1, a0))
        for i in 1...steps { p.addLine(to: pt(r1, a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps))) }
        for i in stride(from: steps, through: 0, by: -1) { p.addLine(to: pt(r0, a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps))) }
        p.closeSubpath()
        return p
    }
}

@available(macOS 26, *)
struct GlassWheelView: View {
    @ObservedObject var model: WheelModel
    let style: WheelGlass

    private var lime: Color { Color(nsColor: Brand.lime) }
    private func base(_ tint: Color?) -> Glass {
        (style == .clear ? Glass.clear : Glass.regular).tint(tint).interactive()
    }

    var body: some View {
        let d = model.diameter
        GlassEffectContainer(spacing: 6) {
            ZStack {
                ForEach(model.petals.indices, id: \.self) { i in petal(i, size: d) }
                hub
            }
            .frame(width: d, height: d)
        }
        .frame(width: d, height: d)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { model.appeared = true }
        }
    }

    private func petal(_ i: Int, size d: CGFloat) -> some View {
        let p = model.petals[i]
        let isHover = model.hovered == i
        let tint: Color? = isHover ? lime.opacity(0.75) : p.isConversion ? lime.opacity(0.16) : nil
        let shape = AnnularSector(inner: p.inner, outer: p.outer, start: p.start, end: p.end, grow: isHover ? 6 : 0)
        let mid = (p.start + p.end) / 2, r = (p.inner + p.outer) / 2 + (isHover ? 2 : 0)
        let maxWidth = min(p.outer - p.inner - 8, (p.end - p.start) * r - 6)
        // Stagger the opening spring outward from 12 o'clock.
        let delay = Double(i) * 0.012

        return ZStack {
            Color.clear
                .frame(width: d, height: d)
                .glassEffect(base(tint), in: shape)
            label(p.action, highlighted: isHover, maxWidth: maxWidth)
                .position(x: d / 2 + cos(mid) * r, y: d / 2 - sin(mid) * r)
        }
        .frame(width: d, height: d)
        .scaleEffect(model.appeared ? 1 : 0.55)
        .opacity(model.appeared ? 1 : 0)
        .animation(.spring(response: 0.34, dampingFraction: 0.7).delay(delay), value: model.appeared)
        .animation(.spring(response: 0.22, dampingFraction: 0.6), value: isHover)
    }

    private func label(_ action: WheelAction, highlighted: Bool, maxWidth: CGFloat) -> some View {
        let color: Color = highlighted ? Color(white: 0.05) : .primary
        return VStack(spacing: 2) {
            if let symbol = action.symbol {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                Text(action.label).font(.system(size: 9, weight: .semibold))
            } else {
                Text(action.label).font(.system(size: 13, weight: .bold))
            }
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(maxWidth: max(maxWidth, 20))
    }

    private var hub: some View {
        let h = model.hub
        return VStack(spacing: 2) {
            Text(model.title).font(.system(size: 15, weight: .bold))
            Text(model.subtitle).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(width: 2 * h - 14)
        .frame(width: 2 * h, height: 2 * h)
        .glassEffect(base(lime.opacity(0.55)), in: Circle())
        .scaleEffect(model.appeared ? 1 : 0.7)
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: model.hovered)
    }
}
