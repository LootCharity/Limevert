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

    /// Template image for the menu bar: a slice outline with segments.
    static func menuBarImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let r = rect.insetBy(dx: 1.5, dy: 1.5)
            NSColor.black.set()
            let ring = NSBezierPath(ovalIn: r)
            ring.lineWidth = 1.6
            ring.stroke()
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let radius = r.width / 2 - 2.6
            for i in 0..<6 {
                let a = CGFloat(i) * .pi / 3 + .pi / 6
                let p = NSBezierPath()
                p.move(to: c)
                p.line(to: NSPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius))
                p.lineWidth = 1.2
                p.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
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
                if state.page > 0 { Button("Back") { withAnimation { state.page -= 1 } }.buttonStyle(.bordered) }
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
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color(nsColor: Brand.limeDeep))
            }
            .padding(20)
        }
        .frame(width: 560, height: 470)
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
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))
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
                .frame(width: 48, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: Brand.lime).opacity(0.15)))
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
