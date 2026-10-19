import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// A Float: a small always-on-top shelf that holds files so you can carry them between apps.
@MainActor
enum FloatShelf {
    private static var controllers: [FloatWindowController] = []

    static func create(with urls: [URL] = []) {
        let c = FloatWindowController(urls: urls, offset: controllers.count)
        controllers.append(c)
        c.onClose = { [weak c] in controllers.removeAll { $0 === c } }
        c.show()
    }

    static var count: Int { controllers.count }
    static func closeAll() { controllers.forEach { $0.close() } }
}

final class FloatModel: ObservableObject {
    @Published var items: [URL] = []
    @Published var selection: Set<URL> = []
    @Published var dropTargeted = false

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(url) { items.append(url) }
    }
    func remove(_ url: URL) { items.removeAll { $0 == url }; selection.remove(url) }
}

@MainActor
final class FloatWindowController: NSObject, NSWindowDelegate {
    let model = FloatModel()
    private let panel: NSPanel
    var onClose: () -> Void = {}

    init(urls: [URL], offset: Int) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 300),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                        backing: .buffered, defer: false)
        super.init()
        model.add(urls)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 200, height: 180)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: FloatView(model: model, close: { [weak self] in self?.close() }))
        if let screen = NSScreen.main?.visibleFrame {
            let shift = CGFloat(offset) * 28
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 280 - shift, y: screen.midY - 150 - shift))
        }
    }

    func show() { panel.orderFrontRegardless() }
    func close() { panel.close() }
    func windowWillClose(_ notification: Notification) { onClose() }
}

struct FloatView: View {
    @ObservedObject var model: FloatModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                LimeMark().frame(width: 16, height: 16)
                Text(model.items.isEmpty ? "Float" : "\(model.items.count) item\(model.items.count == 1 ? "" : "s")")
                    .font(.headline)
                Spacer()
                if !model.items.isEmpty {
                    DragAllHandle(urls: model.selection.isEmpty ? model.items : model.items.filter(model.selection.contains))
                        .frame(width: 22, height: 22)
                        .help("Drag to carry all files")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 30)
            .padding(.bottom, 8)

            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 30, weight: .light))
                    Text("Drop files here").font(.callout)
                    Text("They stay here until you drag them out.").font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(model.dropTargeted ? Color(nsColor: Brand.limeDeep) : .secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .foregroundStyle(model.dropTargeted ? Color(nsColor: Brand.lime) : Color.secondary.opacity(0.35))
                )
                .padding([.horizontal, .bottom], 12)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 10) {
                        ForEach(model.items, id: \.self) { url in
                            FloatTile(url: url, selected: model.selection.contains(url))
                                .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                                .onTapGesture {
                                    if NSEvent.modifierFlags.contains(.command) {
                                        if model.selection.contains(url) { model.selection.remove(url) } else { model.selection.insert(url) }
                                    } else { model.selection = [url] }
                                }
                                .onDrag { NSItemProvider(object: url as NSURL) }
                                .contextMenu {
                                    Button("Open") { NSWorkspace.shared.open(url) }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    Button("Quick Look") { QuickLook.show(url) }
                                    Divider()
                                    Button("Remove from Float") { model.remove(url) }
                                }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(model.dropTargeted ? Color(nsColor: Brand.lime) : .clear, lineWidth: 3)
        )
        .onDrop(of: [.fileURL], isTargeted: $model.dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.add([url]) } }
                }
            }
            return true
        }
        .contextMenu {
            Button("Clear Float") { model.items.removeAll(); model.selection.removeAll() }
            Button("Close Float without deleting files", action: close)
        }
    }
}

struct FloatTile: View {
    let url: URL
    let selected: Bool
    @StateObject private var thumb = ThumbnailLoader()

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: thumb.image ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
            Text(url.lastPathComponent).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                .truncationMode(.middle)
        }
        .padding(6)
        .frame(width: 76)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color(nsColor: Brand.lime).opacity(0.3) : thumb.hovering ? Color.secondary.opacity(0.12) : .clear)
        )
        .onHover { thumb.hovering = $0 }
        .task {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 112, height: 112),
                                                   scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                thumb.image = rep.nsImage
            }
        }
    }
}

final class ThumbnailLoader: ObservableObject {
    @Published var image: NSImage?
    @Published var hovering = false
}

/// AppKit drag source that carries several files at once (SwiftUI's onDrag carries one).
struct DragAllHandle: NSViewRepresentable {
    let urls: [URL]
    func makeNSView(context: Context) -> DragAllView { DragAllView() }
    func updateNSView(_ view: DragAllView, context: Context) { view.urls = urls }
}

final class DragAllView: NSView, NSDraggingSource {
    var urls: [URL] = []

    override func draw(_ dirtyRect: NSRect) {
        let img = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Drag all")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))?.tinted(Brand.limeDeep)
        img?.draw(in: bounds.insetBy(dx: 2, dy: 2))
    }

    override func mouseDown(with event: NSEvent) {
        let items = urls.enumerated().map { i, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            item.setDraggingFrame(NSRect(x: CGFloat(i) * 4, y: CGFloat(i) * -4, width: 32, height: 32), contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : .copy
    }
}

enum QuickLook {
    static func show(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-p", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
