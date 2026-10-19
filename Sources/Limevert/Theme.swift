import AppKit
import Combine
import SwiftUI

/// The single switch between the Liquid Glass design and the classic look.
/// Every surface asks `Theme.glassEnabled` and styles itself through the modifiers below,
/// so turning the setting off (or running before macOS 26) gives the classic design everywhere.
enum Theme {
    static var glassSupported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// Lets tests exercise the fallback as it would look before macOS 26.
    nonisolated(unsafe) static var simulateUnsupported = false

    static var glassEnabled: Bool { glassSupported && !simulateUnsupported && Settings.shared.liquidGlass }

    static let lime = Color(nsColor: Brand.lime)
    static let limeDeep = Color(nsColor: Brand.limeDeep)

    @available(macOS 26, *)
    static func glass(tint: Color? = nil) -> Glass {
        (Settings.shared.glassStyle == .clear ? Glass.clear : Glass.regular).tint(tint)
    }
}

/// Window chrome for glass: content runs under a transparent title bar.
@MainActor
enum WindowTheme {
    static let identifier = NSUserInterfaceItemIdentifier("limevert.themed")
    private static var observer: AnyCancellable?

    static func adopt(_ window: NSWindow) {
        window.identifier = identifier
        apply(window)
        observe()
    }

    static func apply(_ window: NSWindow) {
        let glass = Theme.glassEnabled
        if glass { window.styleMask.insert(.fullSizeContentView) } else { window.styleMask.remove(.fullSizeContentView) }
        window.titlebarAppearsTransparent = glass
    }

    /// Restyles every open themed window when the setting changes.
    private static func observe() {
        guard observer == nil else { return }
        observer = Settings.shared.objectWillChange.sink { _ in
            // objectWillChange fires before the new value is stored.
            DispatchQueue.main.async {
                for w in NSApp.windows where w.identifier == identifier { apply(w) }
            }
        }
    }
}

// MARK: - Modifiers

/// A panel or card: glass when enabled, otherwise a material with a hairline edge.
struct LimeSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color?
    @ObservedObject private var settings = Settings.shared

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *), Theme.glassEnabled {
            content.glassEffect(Theme.glass(tint: tint), in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
        }
    }
}

/// Buttons: glass and glass-prominent styles when enabled, otherwise bordered.
struct LimeButton: ViewModifier {
    var prominent = false
    @ObservedObject private var settings = Settings.shared

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *), Theme.glassEnabled {
            if prominent {
                content.buttonStyle(.glassProminent).tint(Theme.limeDeep)
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent).tint(Theme.limeDeep)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// Selectable tiles inside a panel. Plain fills rather than glass, so there is no glass stacked on glass.
struct LimeChip: ViewModifier {
    let selected: Bool
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(selected ? Theme.lime.opacity(0.38) : Color.primary.opacity(0.07)))
            .overlay(shape.strokeBorder(selected ? Theme.limeDeep.opacity(0.8) : .clear, lineWidth: 1.5))
    }
}

extension View {
    func limeSurface<S: InsettableShape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(LimeSurface(shape: shape, tint: tint))
    }
    func limeButton(prominent: Bool = false) -> some View { modifier(LimeButton(prominent: prominent)) }
    func limeChip(selected: Bool, cornerRadius: CGFloat = 10) -> some View {
        modifier(LimeChip(selected: selected, cornerRadius: cornerRadius))
    }
}
