import AppKit
import SwiftUI

/// Executes a wheel action: instant actions run on the spot, everything else runs in the background with progress.
@MainActor
enum ActionRunner {
    static func run(_ action: WheelAction, on urls: [URL]) {
        switch action {
        case .tool(.float): FloatShelf.create(with: urls)
        case .tool(.copyPaths): InstantActions.copyPaths(urls)
        case .tool(.copyFiles): InstantActions.copyFiles(urls)
        case .tool(.airDrop): InstantActions.airDrop(urls)
        case .tool(.terminal): InstantActions.openTerminal(urls)
        case .tool(.moveTo): InstantActions.moveTo(urls)
        case .tool(.readQR): readQR(urls)
        default: background(action, urls)
        }
    }

    private static func background(_ action: WheelAction, _ urls: [URL]) {
        let task = HUD.shared.begin("\(action.label) · \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")")
        Task.detached(priority: .userInitiated) {
            var outputs: [URL] = []
            var failures: [String] = []
            switch action {
            case .convert(let fmt):
                for (i, url) in urls.enumerated() {
                    do { outputs += try await Converter.convert(url, to: fmt) }
                    catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                    await MainActor.run { HUD.shared.progress(task, Double(i + 1) / Double(urls.count)) }
                }
            case .tool(let tool):
                do { outputs = try await FileTools.run(tool, on: urls) }
                catch { failures.append(error.localizedDescription) }
            }
            let done = outputs, failed = failures
            await MainActor.run { finish(task, action: action, outputs: done, failures: failed) }
        }
    }

    private static func finish(_ task: UUID, action: WheelAction, outputs: [URL], failures: [String]) {
        HUD.shared.end(task)
        TaskHistory.shared.record(action.label, outputs: outputs, failures: failures)
        if failures.isEmpty {
            Feedback.success()
            HUD.shared.flash(outputs.count == 1 ? "Saved \(outputs[0].lastPathComponent)" : "Saved \(outputs.count) files")
        } else {
            Feedback.failure()
            let alert = NSAlert()
            alert.messageText = outputs.isEmpty ? "\(action.label) failed" : "Finished with errors"
            alert.informativeText = failures.prefix(6).joined(separator: "\n")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        if Settings.shared.revealOutputs, !outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
    }

    private static func readQR(_ urls: [URL]) {
        let task = HUD.shared.begin("Reading QR codes")
        Task.detached {
            let result = Result { try FileTools.readQRCodes(urls) }
            await MainActor.run {
                HUD.shared.end(task)
                switch result {
                case .success(let codes) where codes.isEmpty:
                    Feedback.failure(); HUD.shared.flash("No QR codes found", isError: true)
                case .success(let codes):
                    Feedback.success(); QRResultsWindow.show(codes)
                case .failure(let error):
                    Feedback.failure(); HUD.shared.flash(error.localizedDescription, isError: true)
                }
            }
        }
    }
}

@MainActor
enum Feedback {
    static func pop() { if Settings.shared.soundFeedback { NSSound(named: "Pop")?.play() } }
    static func tick() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    static func success() { if Settings.shared.soundFeedback { NSSound(named: "Glass")?.play() } }
    static func failure() { if Settings.shared.soundFeedback { NSSound(named: "Basso")?.play() } }
}

/// Recent results shown in the menu bar menu.
@MainActor
final class TaskHistory {
    static let shared = TaskHistory()
    struct Entry { let title: String; let outputs: [URL]; let failed: Bool }
    private(set) var entries: [Entry] = []

    func record(_ title: String, outputs: [URL], failures: [String]) {
        entries.insert(Entry(title: title, outputs: outputs, failed: !failures.isEmpty), at: 0)
        entries = Array(entries.prefix(8))
    }
}

// MARK: - Progress HUD

@MainActor
final class HUD {
    static let shared = HUD()
    private var panel: NSPanel?
    private let model = HUDModel()
    private var flashWork: DispatchWorkItem?

    func begin(_ title: String) -> UUID {
        let id = UUID()
        model.tasks.append(.init(id: id, title: title, progress: nil))
        model.message = nil
        present()
        return id
    }

    func progress(_ id: UUID, _ value: Double) {
        if let i = model.tasks.firstIndex(where: { $0.id == id }) { model.tasks[i].progress = value }
    }

    func end(_ id: UUID) {
        model.tasks.removeAll { $0.id == id }
        if model.tasks.isEmpty && model.message == nil { dismiss() }
    }

    func flash(_ message: String, isError: Bool = false) {
        model.message = message
        model.isError = isError
        present()
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.model.message = nil
            if self.model.tasks.isEmpty { self.dismiss() } else { self.present() }
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    private func present() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .statusBar
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: HUDView(model: model))
            panel = p
        }
        guard let panel, let screen = NSScreen.main else { return }
        // Let SwiftUI apply the model change before measuring.
        DispatchQueue.main.async {
            let size = panel.contentView?.fittingSize ?? NSSize(width: 300, height: 60)
            let visible = screen.visibleFrame
            panel.setFrame(NSRect(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 12,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
    }

    private func dismiss() { panel?.orderOut(nil) }
}

final class HUDModel: ObservableObject {
    struct Item: Identifiable { let id: UUID; let title: String; var progress: Double? }
    @Published var tasks: [Item] = []
    @Published var message: String?
    @Published var isError = false
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.tasks) { task in
                HStack(spacing: 10) {
                    LimeMark().frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Limevert is working").font(.caption2).foregroundStyle(.secondary)
                        Text(task.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        if let p = task.progress { ProgressView(value: p).tint(Color(nsColor: Brand.lime)) }
                        else { ProgressView().progressViewStyle(.linear).tint(Color(nsColor: Brand.lime)) }
                    }
                }
            }
            if let message = model.message {
                HStack(spacing: 8) {
                    Image(systemName: model.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.isError ? Color.orange : Color(nsColor: Brand.lime))
                    Text(message).font(.callout.weight(.medium)).lineLimit(2)
                }
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - QR results

@MainActor
enum QRResultsWindow {
    private static var window: NSWindow?

    static func show(_ codes: [(file: String, payload: String)]) {
        let view = QRResultsView(codes: codes.map { QRCode(file: $0.file, payload: $0.payload) })
        let w = window ?? NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "QR Codes"
        w.contentViewController = NSHostingController(rootView: view)
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 440, height: min(120 + 64 * codes.count, 520)))
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct QRCode: Identifiable { let id = UUID(); let file: String; let payload: String }

struct QRResultsView: View {
    let codes: [QRCode]
    var body: some View {
        List(codes) { code in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(code.payload).textSelection(.enabled).lineLimit(3)
                    Text(code.file).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let url = URL(string: code.payload), url.scheme?.hasPrefix("http") == true {
                    Button("Open") { NSWorkspace.shared.open(url) }
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.payload, forType: .string)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
