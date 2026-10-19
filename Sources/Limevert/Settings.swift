import AppKit
import ServiceManagement
import SwiftUI

/// Modifier combination the user taps while dragging files to open the wheel.
enum DragShortcut: String, CaseIterable, Identifiable {
    case option, control, command, controlOption, optionCommand

    var id: String { rawValue }
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .option: [.option]
        case .control: [.control]
        case .command: [.command]
        case .controlOption: [.control, .option]
        case .optionCommand: [.option, .command]
        }
    }
    var keys: [String] {
        switch self {
        case .option: ["⌥ Option"]
        case .control: ["⌃ Control"]
        case .command: ["⌘ Command"]
        case .controlOption: ["⌃ Control", "⌥ Option"]
        case .optionCommand: ["⌥ Option", "⌘ Command"]
        }
    }
    var label: String { keys.joined(separator: " + ") }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var shortcut: DragShortcut { didSet { d.set(shortcut.rawValue, forKey: "shortcut") } }
    @Published var soundFeedback: Bool { didSet { d.set(soundFeedback, forKey: "soundFeedback") } }
    @Published var revealOutputs: Bool { didSet { d.set(revealOutputs, forKey: "revealOutputs") } }
    @Published var terminalApp: String { didSet { d.set(terminalApp, forKey: "terminalApp") } }
    @Published var imageQuality: Double { didSet { d.set(imageQuality, forKey: "imageQuality") } }
    @Published var compressionQuality: Double { didSet { d.set(compressionQuality, forKey: "compressionQuality") } }
    @Published var compressMaxEdgeIndex: Int { didSet { d.set(compressMaxEdgeIndex, forKey: "compressMaxEdgeIndex") } }
    @Published var keepFormatWhenCompressing: Bool { didSet { d.set(keepFormatWhenCompressing, forKey: "keepFormat") } }
    /// 0 = 1080p HEVC, 1 = 720p, 2 = 540p.
    @Published var videoCompression: Int { didSet { d.set(videoCompression, forKey: "videoCompression") } }
    @Published var hasSeenWelcome: Bool { didSet { d.set(hasSeenWelcome, forKey: "hasSeenWelcome") } }
    @Published var glassStyle: GlassStyle { didSet { d.set(glassStyle.rawValue, forKey: "wheelGlass") } }
    /// Liquid Glass design for the wheel, editors and windows (macOS 26 and later).
    @Published var liquidGlass: Bool { didSet { d.set(liquidGlass, forKey: "liquidGlass") } }

    static let maxEdgeChoices: [Int?] = [nil, 3840, 2560, 1920, 1280]
    var compressMaxEdge: Int? { Self.maxEdgeChoices[min(compressMaxEdgeIndex, Self.maxEdgeChoices.count - 1)] }

    private init() {
        d.register(defaults: [
            "shortcut": DragShortcut.option.rawValue, "soundFeedback": true, "revealOutputs": false,
            "terminalApp": "Terminal", "imageQuality": 0.9, "compressionQuality": 0.6,
            "compressMaxEdgeIndex": 0, "keepFormat": false, "videoCompression": 1, "hasSeenWelcome": false,
            "liquidGlass": true,
        ])
        shortcut = DragShortcut(rawValue: d.string(forKey: "shortcut") ?? "") ?? .option
        soundFeedback = d.bool(forKey: "soundFeedback")
        revealOutputs = d.bool(forKey: "revealOutputs")
        terminalApp = d.string(forKey: "terminalApp") ?? "Terminal"
        imageQuality = d.double(forKey: "imageQuality")
        compressionQuality = d.double(forKey: "compressionQuality")
        compressMaxEdgeIndex = d.integer(forKey: "compressMaxEdgeIndex")
        keepFormatWhenCompressing = d.bool(forKey: "keepFormat")
        videoCompression = d.integer(forKey: "videoCompression")
        hasSeenWelcome = d.bool(forKey: "hasSeenWelcome")
        glassStyle = GlassStyle(rawValue: d.string(forKey: "wheelGlass") ?? "") ?? .regular
        liquidGlass = d.bool(forKey: "liquidGlass")
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch {
                let message = "Couldn’t change login item: \(error.localizedDescription)"
                DispatchQueue.main.async { HUD.shared.flash(message, isError: true) }
            }
            objectWillChange.send()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        TabView {
            Form {
                Section("Drag shortcut") {
                    Picker("Tap while dragging", selection: $settings.shortcut) {
                        ForEach(DragShortcut.allCases) { Text($0.label).tag($0) }
                    }
                    Text("Drag files anywhere, then tap the shortcut to open the conversion wheel.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Appearance") {
                    if Theme.glassSupported {
                        Toggle("Liquid Glass design", isOn: $settings.liquidGlass)
                        if settings.liquidGlass {
                            Picker("Glass style", selection: $settings.glassStyle) {
                                ForEach(GlassStyle.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        Text("Applies to the wheel, the editors and Limevert's windows. Turn it off for the classic look.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Liquid Glass needs macOS 26 or later. Limevert uses the classic look on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("General") {
                    Toggle("Launch Limevert at login", isOn: Binding(
                        get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                    Toggle("Sound feedback", isOn: $settings.soundFeedback)
                    Toggle("Reveal results in Finder", isOn: $settings.revealOutputs)
                    Picker("Terminal app", selection: $settings.terminalApp) {
                        ForEach(TerminalApp.choices, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Conversion") {
                    LabeledContent("JPEG / HEIC / WebP quality") {
                        Slider(value: $settings.imageQuality, in: 0.4...1.0) { Text("") }
                            .frame(width: 180)
                        Text("\(Int(settings.imageQuality * 100))%").monospacedDigit().frame(width: 40)
                    }
                }
                Section("Image compression") {
                    LabeledContent("Quality") {
                        Slider(value: $settings.compressionQuality, in: 0.2...0.9) { Text("") }
                            .frame(width: 180)
                        Text("\(Int(settings.compressionQuality * 100))%").monospacedDigit().frame(width: 40)
                    }
                    Picker("Maximum size", selection: $settings.compressMaxEdgeIndex) {
                        ForEach(Settings.maxEdgeChoices.indices, id: \.self) { i in
                            Text(Settings.maxEdgeChoices[i].map { "\($0) px longest edge" } ?? "Keep original dimensions").tag(i)
                        }
                    }
                    Toggle("Keep PNG and TIFF formats (otherwise save as HEIC)", isOn: $settings.keepFormatWhenCompressing)
                }
                Section("Video compression") {
                    Picker("Preset", selection: $settings.videoCompression) {
                        Text("1080p HEVC — smaller files with less quality loss").tag(0)
                        Text("720p H.264 — balanced").tag(1)
                        Text("540p H.264 — smallest files").tag(2)
                    }
                }
                Section {
                    Button("Restore Compression Defaults") {
                        settings.imageQuality = 0.9; settings.compressionQuality = 0.6
                        settings.compressMaxEdgeIndex = 0; settings.keepFormatWhenCompressing = false
                        settings.videoCompression = 1
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Compression", systemImage: "arrow.down.right.and.arrow.up.left") }

            FormatMatrixView()
                .tabItem { Label("Formats", systemImage: "square.grid.3x3") }
        }
        .frame(width: 520, height: 440)
    }
}

/// Supported-formats overview, grouped by source kind.
struct FormatMatrixView: View {
    private let groups: [(String, String, [String])] = [
        ("Images", "photo", ["PNG", "JPEG", "HEIC", "AVIF", "WebP", "TIFF", "GIF", "BMP", "ICNS", "PDF",
                             "Crop", "Adjust", "Annotate", "Redact", "Frame", "Collage", "Remove BG", "Flip"]),
        ("Video", "film", ["MP4", "MOV", "M4V", "GIF", "M4A audio", "Trim", "Split", "Speed", "Snapshot", "Mute", "Join"]),
        ("Audio", "waveform", ["M4A (AAC)", "ALAC", "WAV", "AIFF", "FLAC", "CAF", "Trim", "Bleep", "Normalize",
                               "Mono", "Stereo", "Visualizer"]),
        ("PDF", "doc.richtext", ["PNG pages", "JPEG pages", "TXT", "RTF", "Merge", "Split Pages", "Organize", "Compress"]),
        ("Documents", "doc.text", ["DOCX", "PDF", "RTF", "TXT", "HTML", "ODT", "Markdown"]),
        ("Subtitles", "captions.bubble", ["SRT", "VTT"]),
        ("Any file", "folder", ["Float", "Zip", "Copy Paths", "AirDrop", "Move To…", "Terminal"]),
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groups, id: \.0) { name, symbol, outputs in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(name, systemImage: symbol).font(.headline)
                        FlowRow(items: outputs)
                    }
                }
                Text("WebP output depends on your macOS version’s ImageIO encoders.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct FlowRow: View {
    let items: [String]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item).font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(Capsule().fill(Color(nsColor: Brand.lime).opacity(0.18)))
            }
        }
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Limevert Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            WindowTheme.adopt(w)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
