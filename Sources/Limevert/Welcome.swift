import AppKit
import SwiftUI

/// Lime-slice brand mark, drawn in code so the app ships without image assets.
struct LimeMark: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let pith = Color(red: 0.93, green: 0.98, blue: 0.80)
            ZStack {
                Circle().fill(Color(nsColor: Brand.limeDeep))
                Circle().inset(by: s * 0.08).fill(pith)
                Circle().inset(by: s * 0.14).fill(Color(nsColor: Brand.lime))
                ForEach(0..<8) { i in
                    Rectangle().fill(pith)
                        .frame(width: max(1, s * 0.04), height: s * 0.36)
                        .offset(y: -s * 0.18)
                        .rotationEffect(.degrees(Double(i) * 45))
                }
                Circle().fill(pith).frame(width: s * 0.1, height: s * 0.1)
            }
            .frame(width: s, height: s)
        }
    }

    /// Template image for the menu bar: a lime slice (rind, six segments) with a leaf at the top right.
    static func menuBarImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.set()
            let c = NSPoint(x: rect.midX - 1.6, y: rect.midY - 1.4)
            let rind: CGFloat = 7.3, pith = rind - 1.5
            NSBezierPath(ovalIn: NSRect(x: c.x - rind, y: c.y - rind, width: 2 * rind, height: 2 * rind)).fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: c.x - pith, y: c.y - pith, width: 2 * pith, height: 2 * pith)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            let flesh = pith - 0.9, step = CGFloat.pi / 3, gap: CGFloat = 0.42
            for i in 0..<6 {
                let a0 = CGFloat(i) * step + gap / 2, a1 = a0 + step - gap
                let p = NSBezierPath()
                p.move(to: NSPoint(x: c.x + cos((a0 + a1) / 2) * 1.3, y: c.y + sin((a0 + a1) / 2) * 1.3))
                p.line(to: NSPoint(x: c.x + cos(a0) * flesh, y: c.y + sin(a0) * flesh))
                p.appendArc(withCenter: c, radius: flesh, startAngle: a0 * 180 / .pi, endAngle: a1 * 180 / .pi)
                p.close()
                p.fill()
            }

            // Leaf: clear a slightly larger halo first so it separates from the rind.
            let base = NSPoint(x: c.x + 4.4, y: c.y + 4.4)
            let t = NSAffineTransform()
            t.translateX(by: base.x, yBy: base.y)
            t.rotate(byDegrees: 30)
            NSGraphicsContext.current?.compositingOperation = .clear
            let halo = NSBezierPath(ovalIn: NSRect(x: -0.6, y: -2.3, width: 6.8, height: 4.6))
            halo.transform(using: t as AffineTransform)
            halo.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let L: CGFloat = 5.6, W: CGFloat = 1.9
            let leaf = NSBezierPath()
            leaf.move(to: .zero)
            leaf.curve(to: NSPoint(x: L, y: 0), controlPoint1: NSPoint(x: L * 0.3, y: W), controlPoint2: NSPoint(x: L * 0.75, y: W * 0.8))
            leaf.curve(to: .zero, controlPoint1: NSPoint(x: L * 0.75, y: -W * 0.8), controlPoint2: NSPoint(x: L * 0.3, y: -W))
            leaf.close()
            leaf.transform(using: t as AffineTransform)
            leaf.fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// Feature icon tile: clear glass with the lime icon when enabled, a soft lime fill otherwise.
struct WelcomeTile: ViewModifier {
    @ObservedObject private var settings = Settings.shared

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if Theme.glassEnabled {
            content.limeSurface(in: shape)
        } else {
            content.background(shape.fill(Color(nsColor: Brand.lime).opacity(0.15)))
        }
    }
}

@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: WelcomeView(close: { window?.close() }))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class WelcomeState: ObservableObject {
    @Published var page = 0
    @Published var loginEnabled = Settings.shared.launchAtLogin
}

struct WelcomeView: View {
    let close: () -> Void
    @ObservedObject private var settings = Settings.shared
    @StateObject private var state = WelcomeState()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch state.page {
                case 0: intro
                case 1: shortcut
                default: finish
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .padding(.horizontal, 40)
            .padding(.top, 36)

            HStack {
                if state.page > 0 { Button("Back") { withAnimation { state.page -= 1 } }.limeButton() }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Capsule().fill(i == state.page ? Color(nsColor: Brand.lime) : Color.secondary.opacity(0.3))
                            .frame(width: i == state.page ? 18 : 7, height: 7)
                    }
                }
                Spacer()
                Button(state.page == 2 ? "Get Started" : "Continue") {
                    if state.page == 2 { settings.hasSeenWelcome = true; close() } else { withAnimation { state.page += 1 } }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .limeButton(prominent: true)
            }
            .padding(20)
        }
        .frame(width: 560, height: 470)
        .background(Theme.glassEnabled ? AnyView(GlassBackdrop().ignoresSafeArea()) : AnyView(Color.clear))
    }

    private var intro: some View {
        VStack(spacing: 16) {
            LimeMark().frame(width: 96, height: 96)
                .shadow(color: Color(nsColor: Brand.limeDeep).opacity(0.35), radius: 14, y: 6)
            Text("Welcome to Limevert").font(.largeTitle.bold())
            Text("Convert, compress and carry files without opening another app. Limevert lives in your menu bar and saves results beside the originals.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack(spacing: 22) {
                feature("photo.on.rectangle", "Images")
                feature("film", "Video")
                feature("waveform", "Audio")
                feature("doc.richtext", "PDF & Docs")
                feature("rectangle.stack", "Float")
            }
            .padding(.top, 8)
        }
    }

    private var shortcut: some View {
        VStack(spacing: 18) {
            Text("The conversion wheel").font(.title.bold())
            VStack(alignment: .leading, spacing: 12) {
                step(1, "Drag files", "Start dragging from Finder, the Desktop, or any app.")
                step(2, "While dragging, tap \(settings.shortcut.label)", "A wheel of formats and tools opens under your pointer.")
                step(3, "Drop on a petal", "Limevert converts in the background and saves next to the original.")
            }
            HStack(spacing: 8) {
                ForEach(settings.shortcut.keys, id: \.self) { key in
                    Text(key).font(.system(.title3, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .limeSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            Picker("Shortcut", selection: $settings.shortcut) {
                ForEach(DragShortcut.allCases) { Text($0.label).tag($0) }
            }
            .frame(width: 300)
            Text("You can also drop files on the menu bar icon, or choose Convert Files… from its menu.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var finish: some View {
        VStack(spacing: 18) {
            LimeMark().frame(width: 64, height: 64)
            Text("Ready whenever you are").font(.title.bold())
            Toggle("Launch Limevert at login", isOn: $state.loginEnabled)
                .toggleStyle(.switch)
                .onChange(of: state.loginEnabled) { _, on in settings.launchAtLogin = on }
            Toggle("Sound feedback", isOn: $settings.soundFeedback).toggleStyle(.switch)
            Text("You can change these options and your shortcut in Settings.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(width: 340)
    }

    private func feature(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color(nsColor: Brand.limeDeep))
                .frame(width: 52, height: 44)
                .modifier(WelcomeTile())
            Text(title).font(.caption)
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline).frame(width: 26, height: 26)
                .background(Circle().fill(Color(nsColor: Brand.lime)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
