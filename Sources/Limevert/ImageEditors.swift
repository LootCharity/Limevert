import AppKit
import SwiftUI

// MARK: - Editor windows

/// Opens the editor for a tool. Editors save through `ActionRunner.perform`, so results get the usual HUD, sound and history.
@MainActor
enum Editors {
    private static var windows: [NSWindow] = []

    static func open(_ tool: FileToolKind, _ urls: [URL]) {
        guard let first = urls.first else { return }
        do {
            switch tool {
            case .crop: let m = CropModel(try LoadedImage(first)); present("Crop", first) { CropEditor(model: m, close: $0) }
            case .adjust: let m = AdjustModel(try LoadedImage(first)); present("Adjust", first) { AdjustEditor(model: m, close: $0) }
            case .annotate: let m = AnnotateModel(try LoadedImage(first)); present("Annotate", first) { AnnotateEditor(model: m, close: $0) }
            case .redact: let m = RedactModel(try LoadedImage(first)); present("Redact", first) { RedactEditor(model: m, close: $0) }
            case .frame: let m = FrameModel(try LoadedImage(first)); present("Frame", first) { FrameEditor(model: m, close: $0) }
            case .collage:
                let m = CollageModel(try urls.map { try LoadedImage($0, previewSize: 500) })
                present("Collage", nil, subtitle: "\(urls.count) images") { CollageEditor(model: m, close: $0) }
            case .trimVideo, .splitVideo, .speed, .snapshot:
                let mode: VideoModel.Mode = switch tool { case .trimVideo: .trim; case .splitVideo: .split; case .speed: .speed; default: .snapshot }
                let m = VideoModel(url: first, mode: mode)
                present(tool == .trimVideo ? "Trim Video" : tool.label, first) { VideoEditor(model: m, close: $0) }
            case .trimAudio, .bleep:
                let m = AudioModel(url: first, mode: tool == .bleep ? .bleep : .trim)
                present(tool == .bleep ? "Bleep" : "Trim Audio", first) { AudioEditor(model: m, close: $0) }
            case .visualize:
                let m = AudioModel(url: first, mode: .visualize)
                present("Audio Visualizer", first) { VisualizerEditor(model: m, close: $0) }
            case .organizePDF:
                let m = OrganizerModel(url: first, document: try PDFs.open(first))
                present("Organize Pages", first) { OrganizerEditor(model: m, close: $0) }
            default: break
            }
        } catch {
            Feedback.failure()
            HUD.shared.flash(error.localizedDescription, isError: true)
        }
    }

    static func present<V: View>(_ title: String, _ file: URL?, subtitle: String? = nil,
                                 _ make: (_ close: @escaping () -> Void) -> V) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title
        w.subtitle = subtitle ?? file?.lastPathComponent ?? ""
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 680, height: 460)
        w.contentView = NSHostingView(rootView: make { [weak w] in w?.close() })
        WindowTheme.adopt(w)
        w.center()
        windows.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { note in
            MainActor.assumeIsolated { windows.removeAll { $0 === note.object as? NSWindow } }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

/// Canvas on the left, controls on the right, Cancel and Save along the bottom.
struct EditorScaffold<Canvas: View, Sidebar: View>: View {
    let primary: String
    var canSave = true
    var status = ""
    let cancel: () -> Void
    let save: () -> Void
    let canvas: Canvas
    let sidebar: Sidebar

    init(primary: String, canSave: Bool = true, status: String = "", cancel: @escaping () -> Void, save: @escaping () -> Void,
         @ViewBuilder canvas: () -> Canvas, @ViewBuilder sidebar: () -> Sidebar) {
        self.primary = primary
        self.canSave = canSave
        self.status = status
        self.cancel = cancel
        self.save = save
        self.canvas = canvas()
        self.sidebar = sidebar()
    }

    @ObservedObject private var settings = Settings.shared

    var body: some View {
        if Theme.glassEnabled { glassLayout } else { classicLayout }
    }

    // Floating glass panels: the backdrop fills the window, the canvas keeps clear of the panels
    // so handles and timelines are never underneath glass.
    private let margin: CGFloat = 14
    private let sidebarWidth: CGFloat = 268
    private let barHeight: CGFloat = 52

    private var glassLayout: some View {
        canvas
            .padding(.trailing, sidebarWidth + margin)
            .padding(.bottom, barHeight + margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(backdrop.ignoresSafeArea())
            .overlay(alignment: .topTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) { sidebar }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                }
                .scrollIndicators(.never)
                .frame(width: sidebarWidth)
                .limeSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding([.top, .trailing], margin)
                .padding(.bottom, barHeight + 2 * margin)
            }
            .overlay(alignment: .bottom) {
                // Separate glass pieces floating over the canvas: no glass stacked on glass.
                HStack(spacing: 10) {
                    if !status.isEmpty {
                        Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .limeSurface(in: Capsule())
                    }
                    Spacer()
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).controlSize(.large).limeButton()
                    Button(primary, action: save)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .limeButton(prominent: true)
                        .disabled(!canSave)
                }
                .frame(height: barHeight)
                .padding(.horizontal, margin + 4)
                .padding(.bottom, margin)
            }
    }

    private var backdrop: some View { GlassBackdrop() }

    private var classicLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) { sidebar }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .frame(width: 260)
            }
            Divider()
            HStack(spacing: 10) {
                Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(primary, action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(nsColor: Brand.limeDeep))
                    .disabled(!canSave)
            }
            .padding(12)
        }
    }
}

struct SidebarSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content
        }
    }
}

/// A labelled slider with its value.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%+.2f", $0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            Slider(value: $value, in: range)
        }
    }
}

/// An image scaled to fit, with an overlay laid out in the displayed image's own coordinates.
struct FittedImage<Overlay: View>: View {
    let image: NSImage
    let pixelSize: CGSize
    var padding: CGFloat = 28
    let overlay: (CGSize) -> Overlay

    init(image: NSImage, pixelSize: CGSize, padding: CGFloat = 28, @ViewBuilder overlay: @escaping (CGSize) -> Overlay) {
        self.image = image
        self.pixelSize = pixelSize
        self.padding = padding
        self.overlay = overlay
    }

    var body: some View {
        GeometryReader { geo in
            let scale = min((geo.size.width - 2 * padding) / max(1, pixelSize.width),
                            (geo.size.height - 2 * padding) / max(1, pixelSize.height))
            let size = CGSize(width: max(1, pixelSize.width * scale), height: max(1, pixelSize.height * scale))
            ZStack(alignment: .topLeading) {
                Checkerboard().frame(width: size.width, height: size.height)
                Image(nsImage: image).resizable().interpolation(.high).frame(width: size.width, height: size.height)
                overlay(size)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

extension FittedImage where Overlay == EmptyView {
    init(image: NSImage, pixelSize: CGSize, padding: CGFloat = 28) {
        self.init(image: image, pixelSize: pixelSize, padding: padding) { _ in EmptyView() }
    }
}

/// Shows through transparent pixels.
struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.96)))
            for row in 0..<Int(size.height / s) + 1 {
                for col in 0..<Int(size.width / s) + 1 where (row + col) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s)), with: .color(Color(white: 0.86)))
                }
            }
        }
    }
}

/// Full image for saving plus a smaller copy for fast previews.
struct LoadedImage {
    let url: URL
    let full: CGImage
    let preview: CGImage

    init(_ url: URL, previewSize: Int = 1600) throws {
        self.url = url
        full = try Images.loadOriented(url)
        preview = max(full.width, full.height) > previewSize ? try Images.loadOriented(url, maxPixel: previewSize) : full
    }

    var size: CGSize { CGSize(width: full.width, height: full.height) }
    var previewImage: NSImage { NSImage(cgImage: preview, size: .zero) }
}

extension ImageEdits.RGBA {
    var color: Color { Color(cgColor: cgColor) }
}

/// Re-renders a preview off the main thread, dropping stale results.
final class PreviewRenderer {
    private let queue = DispatchQueue(label: "limevert.preview", qos: .userInteractive)
    private var generation = 0

    func render(_ work: @escaping () -> CGImage?, then apply: @escaping (NSImage) -> Void) {
        generation += 1
        let id = generation
        queue.async { [weak self] in
            guard let self, id == self.generation, let img = work() else { return }
            let ns = NSImage(cgImage: img, size: .zero)
            DispatchQueue.main.async { if id == self.generation { apply(ns) } }
        }
    }
}

// MARK: - Crop

enum CropRatio: String, CaseIterable, Identifiable {
    case free = "Freeform", original = "Original", square = "Square", fourThree = "4:3", threeTwo = "3:2"
    case wide = "16:9", fourFive = "4:5", tall = "9:16"
    var id: String { rawValue }
    func value(original size: CGSize) -> CGFloat? {
        switch self {
        case .free: nil
        case .original: size.width / max(1, size.height)
        case .square: 1
        case .fourThree: 4 / 3
        case .threeTwo: 3 / 2
        case .wide: 16 / 9
        case .fourFive: 4 / 5
        case .tall: 9 / 16
        }
    }
}

enum Corner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    var opposite: Corner {
        switch self { case .topLeft: .bottomRight; case .topRight: .bottomLeft; case .bottomLeft: .topRight; case .bottomRight: .topLeft }
    }
    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        }
    }
}

final class CropModel: ObservableObject {
    let image: LoadedImage
    @Published var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var ratio = CropRatio.free { didSet { applyRatio() } }
    var moveStart: CGRect?

    init(_ image: LoadedImage) { self.image = image }

    var pixelSize: CGSize { ImageEdits.pixelRect(rect, width: image.full.width, height: image.full.height).size }

    /// Ratio in normalized units (width and height are fractions of different pixel lengths).
    private var normalizedAspect: CGFloat? {
        ratio.value(original: image.size).map { $0 * image.size.height / max(1, image.size.width) }
    }

    func move(by t: CGSize, in size: CGSize) {
        if moveStart == nil { moveStart = rect }
        guard let s = moveStart else { return }
        var r = s.offsetBy(dx: t.width / size.width, dy: t.height / size.height)
        r.origin.x = min(max(0, r.minX), 1 - r.width)
        r.origin.y = min(max(0, r.minY), 1 - r.height)
        rect = r
    }

    func drag(_ corner: Corner, to p: CGPoint) {
        let o = corner.opposite.point(in: rect)
        let q = CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
        var w = abs(q.x - o.x), h = abs(q.y - o.y)
        if let a = normalizedAspect {
            if w / max(h, 0.0001) > a { w = h * a } else { h = w / a }
        }
        w = max(w, 0.03)
        h = max(h, 0.03)
        let x = q.x < o.x ? o.x - w : o.x
        let y = q.y < o.y ? o.y - h : o.y
        rect = CGRect(x: x, y: y, width: w, height: h).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func applyRatio() {
        guard let a = normalizedAspect else { return }
        var w = rect.width, h = rect.height
        if w / h > a { w = h * a } else { h = w / a }
        rect = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    func reset() {
        ratio = .free
        rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    }
}

struct CropEditor: View {
    @ObservedObject var model: CropModel
    let close: () -> Void

    var body: some View {
        EditorScaffold(primary: "Save Crop", status: "\(Int(model.pixelSize.width)) × \(Int(model.pixelSize.height)) px",
                       cancel: close, save: save) {
            FittedImage(image: model.image.previewImage, pixelSize: model.image.size) { size in
                CropOverlay(model: model, size: size)
            }
        } sidebar: {
            SidebarSection("Aspect ratio") {
                Picker("Aspect ratio", selection: $model.ratio) {
                    ForEach(CropRatio.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            SidebarSection("Size") {
                Text("\(Int(model.pixelSize.width)) × \(Int(model.pixelSize.height)) pixels").monospacedDigit()
                Text("of \(Int(model.image.size.width)) × \(Int(model.image.size.height))").font(.caption).foregroundStyle(.secondary)
            }
            Button("Reset") { model.reset() }
            Text("Drag the corners to resize, or drag inside the selection to move it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        let img = model.image, r = model.rect
        ActionRunner.perform("Crop · \(img.url.lastPathComponent)", history: "Crop") { _ in
            [try ImageEdits.save(try ImageEdits.crop(img.full, to: r), beside: img.url, suffix: "cropped")]
        }
        close()
    }
}

struct CropOverlay: View {
    @ObservedObject var model: CropModel
    let size: CGSize

    var body: some View {
        let r = CGRect(x: model.rect.minX * size.width, y: model.rect.minY * size.height,
                       width: model.rect.width * size.width, height: model.rect.height * size.height)
        ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            Path { p in
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.45), lineWidth: 0.5)
            .allowsHitTesting(false)
            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .contentShape(Rectangle())
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .gesture(DragGesture()
                    .onChanged { model.move(by: $0.translation, in: size) }
                    .onEnded { _ in model.moveStart = nil })
            ForEach(Corner.allCases, id: \.self) { corner in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .position(corner.point(in: r))
                    .gesture(DragGesture(coordinateSpace: .named("crop")).onChanged { v in
                        model.drag(corner, to: CGPoint(x: v.location.x / size.width, y: v.location.y / size.height))
                    })
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: "crop")
    }
}

// MARK: - Adjust

final class AdjustModel: ObservableObject {
    let image: LoadedImage
    @Published var adjustments = ImageEdits.Adjustments() { didSet { refresh() } }
    @Published var rendered: NSImage
    @Published var showOriginal = false
    private let renderer = PreviewRenderer()
    private let small: CGImage

    init(_ image: LoadedImage) {
        self.image = image
        small = (try? Images.loadOriented(image.url, maxPixel: 1200)) ?? image.preview
        rendered = NSImage(cgImage: small, size: .zero)
    }

    private func refresh() {
        let a = adjustments, src = small
        renderer.render({ try? ImageEdits.adjust(src, a) }) { [weak self] in self?.rendered = $0 }
    }
}

struct AdjustEditor: View {
    @ObservedObject var model: AdjustModel
    let close: () -> Void

    var body: some View {
        EditorScaffold(primary: "Save Adjustments", canSave: !model.adjustments.isIdentity, cancel: close, save: save) {
            FittedImage(image: model.showOriginal ? model.image.previewImage : model.rendered, pixelSize: model.image.size)
        } sidebar: {
            SidebarSection("Light") {
                ValueSlider(title: "Exposure", value: $model.adjustments.exposure, range: -2...2)
                ValueSlider(title: "Contrast", value: $model.adjustments.contrast, range: 0.5...1.5, format: percent)
                ValueSlider(title: "Highlights", value: $model.adjustments.highlights, range: 0...1, format: percent)
                ValueSlider(title: "Shadows", value: $model.adjustments.shadows, range: -1...1)
            }
            SidebarSection("Color") {
                ValueSlider(title: "Saturation", value: $model.adjustments.saturation, range: 0...2, format: percent)
                ValueSlider(title: "Warmth", value: $model.adjustments.warmth, range: -1...1)
            }
            SidebarSection("Detail") {
                ValueSlider(title: "Sharpness", value: $model.adjustments.sharpness, range: 0...2) { String(format: "%.2f", $0) }
            }
            Toggle("Show original", isOn: $model.showOriginal)
            Button("Reset All") { model.adjustments = ImageEdits.Adjustments() }
                .disabled(model.adjustments.isIdentity)
        }
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private func save() {
        let img = model.image, a = model.adjustments
        ActionRunner.perform("Adjust · \(img.url.lastPathComponent)", history: "Adjust") { _ in
            [try ImageEdits.save(try ImageEdits.adjust(img.full, a), beside: img.url, suffix: "adjusted")]
        }
        close()
    }
}

// MARK: - Annotate

final class AnnotateModel: ObservableObject {
    let image: LoadedImage
    @Published var marks: [ImageEdits.Mark] = []
    @Published var draft: ImageEdits.Mark?
    @Published var tool = ImageEdits.MarkKind.arrow
    @Published var color = ImageEdits.RGBA.palette[0]
    @Published var width = 0.007
    @Published var text = "Text"

    init(_ image: LoadedImage) { self.image = image }

    func drag(from start: CGPoint, to p: CGPoint) {
        if draft == nil {
            draft = ImageEdits.Mark(kind: tool, points: [start], color: color, width: width, text: text)
        }
        switch tool {
        case .pen, .highlighter: draft?.points.append(p)
        case .arrow, .rectangle, .ellipse: draft?.points = [start, p]
        case .text: draft?.points = [p]
        }
    }

    func commit() {
        guard let d = draft else { return }
        draft = nil
        if d.kind == .text && d.text.trimmingCharacters(in: .whitespaces).isEmpty { return }
        marks.append(d)
    }
}

struct AnnotateEditor: View {
    @ObservedObject var model: AnnotateModel
    let close: () -> Void
    private let sizes: [(String, Double)] = [("S", 0.004), ("M", 0.007), ("L", 0.012)]

    var body: some View {
        EditorScaffold(primary: "Save Annotations", canSave: !model.marks.isEmpty,
                       status: model.marks.isEmpty ? "Drag on the image to draw." : "\(model.marks.count) annotation\(model.marks.count == 1 ? "" : "s")",
                       cancel: close, save: save) {
            FittedImage(image: model.image.previewImage, pixelSize: model.image.size) { size in
                Canvas { ctx, canvasSize in
                    ctx.withCGContext { cg in
                        ImageEdits.draw(model.marks + (model.draft.map { [$0] } ?? []), in: cg, size: canvasSize)
                    }
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        model.drag(from: norm(v.startLocation, size), to: norm(v.location, size))
                    }
                    .onEnded { _ in model.commit() })
            }
        } sidebar: {
            SidebarSection("Tool") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(ImageEdits.MarkKind.allCases) { kind in
                        Button { model.tool = kind } label: {
                            VStack(spacing: 3) {
                                Image(systemName: kind.symbol).font(.system(size: 15))
                                Text(kind.label).font(.caption2)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                            .limeChip(selected: model.tool == kind)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if model.tool == .text {
                SidebarSection("Text") {
                    TextField("Text", text: $model.text)
                    Text("Click on the image to place it.").font(.caption).foregroundStyle(.secondary)
                }
            }
            SidebarSection("Color") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 8), count: 4), spacing: 8) {
                    ForEach(ImageEdits.RGBA.palette.indices, id: \.self) { i in
                        let c = ImageEdits.RGBA.palette[i]
                        Circle()
                            .fill(c.color)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25)))
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: model.color == c ? 2.5 : 0).padding(-3))
                            .frame(width: 22, height: 22)
                            .onTapGesture { model.color = c }
                    }
                }
            }
            SidebarSection("Size") {
                Picker("Size", selection: $model.width) {
                    ForEach(sizes, id: \.1) { Text($0.0).tag($0.1) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack {
                Button("Undo") { _ = model.marks.popLast() }.keyboardShortcut("z", modifiers: .command)
                Button("Clear") { model.marks.removeAll() }
            }
            .disabled(model.marks.isEmpty)
        }
    }

    private func save() {
        let img = model.image, marks = model.marks
        ActionRunner.perform("Annotate · \(img.url.lastPathComponent)", history: "Annotate") { _ in
            [try ImageEdits.save(try ImageEdits.annotate(img.full, marks: marks), beside: img.url, suffix: "annotated")]
        }
        close()
    }
}

func norm(_ p: CGPoint, _ size: CGSize) -> CGPoint {
    CGPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1))
}

// MARK: - Redact

final class RedactModel: ObservableObject {
    let image: LoadedImage
    @Published var rects: [CGRect] = [] { didSet { refresh() } }
    @Published var style = ImageEdits.RedactStyle.pixelate { didSet { refresh() } }
    @Published var draft: CGRect?
    @Published var rendered: NSImage
    @Published var detecting = false
    private let renderer = PreviewRenderer()

    init(_ image: LoadedImage) {
        self.image = image
        rendered = image.previewImage
    }

    private func refresh() {
        let r = rects, s = style, src = image.preview
        renderer.render({ try? ImageEdits.redact(src, rects: r, style: s) }) { [weak self] in self?.rendered = $0 }
    }

    func detect(_ kind: ImageEdits.Detection) {
        detecting = true
        let src = image.preview
        DispatchQueue.global(qos: .userInitiated).async {
            let found = (try? ImageEdits.detect(kind, in: src)) ?? []
            DispatchQueue.main.async {
                self.detecting = false
                if found.isEmpty {
                    HUD.shared.flash(kind == .faces ? "No faces found" : "No text found", isError: true)
                } else {
                    self.rects += found
                }
            }
        }
    }

    /// A click (no drag) on an existing box removes it.
    func click(at p: CGPoint) {
        if let i = rects.lastIndex(where: { $0.contains(p) }) { rects.remove(at: i) }
    }
}

struct RedactEditor: View {
    @ObservedObject var model: RedactModel
    let close: () -> Void

    var body: some View {
        EditorScaffold(primary: "Save Redacted", canSave: !model.rects.isEmpty,
                       status: model.rects.isEmpty ? "Draw a rectangle over the area to hide." : "\(model.rects.count) area\(model.rects.count == 1 ? "" : "s") hidden",
                       cancel: close, save: save) {
            FittedImage(image: model.rendered, pixelSize: model.image.size) { size in
                ZStack(alignment: .topLeading) {
                    ForEach(Array((model.rects + (model.draft.map { [$0] } ?? [])).enumerated()), id: \.offset) { _, r in
                        Rectangle()
                            .strokeBorder(Color(nsColor: Brand.lime), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            .frame(width: r.width * size.width, height: r.height * size.height)
                            .offset(x: r.minX * size.width, y: r.minY * size.height)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let a = norm(v.startLocation, size), b = norm(v.location, size)
                        model.draft = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                    }
                    .onEnded { v in
                        if let d = model.draft, d.width * size.width > 4, d.height * size.height > 4 {
                            model.rects.append(d)
                        } else {
                            model.click(at: norm(v.location, size))
                        }
                        model.draft = nil
                    })
            }
        } sidebar: {
            SidebarSection("Style") {
                Picker("Style", selection: $model.style) {
                    ForEach(ImageEdits.RedactStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            SidebarSection("Find automatically") {
                Button { model.detect(.faces) } label: { Label("Hide Faces", systemImage: "face.dashed") }
                Button { model.detect(.text) } label: { Label("Hide Text", systemImage: "text.viewfinder") }
                if model.detecting { ProgressView().controlSize(.small) }
            }
            HStack {
                Button("Undo") { _ = model.rects.popLast() }.keyboardShortcut("z", modifiers: .command)
                Button("Clear") { model.rects.removeAll() }
            }
            .disabled(model.rects.isEmpty)
            Text("Drag to add an area. Click an area to remove it.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        let img = model.image, rects = model.rects, style = model.style
        ActionRunner.perform("Redact · \(img.url.lastPathComponent)", history: "Redact") { _ in
            [try ImageEdits.save(try ImageEdits.redact(img.full, rects: rects, style: style), beside: img.url, suffix: "redacted")]
        }
        close()
    }
}

// MARK: - Frame

struct BackgroundSwatches: View {
    @Binding var selection: ImageEdits.FrameBackground
    var choices = ImageEdits.FrameBackground.presets

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 5), alignment: .leading, spacing: 8) {
            ForEach(choices) { bg in
                ZStack {
                    if bg.colors.isEmpty {
                        Checkerboard()
                    } else {
                        LinearGradient(colors: bg.colors.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.2)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor, lineWidth: selection == bg ? 2.5 : 0).padding(-3))
                .help(bg.id)
                .onTapGesture { selection = bg }
            }
        }
    }
}

final class FrameModel: ObservableObject {
    let image: LoadedImage
    @Published var options = ImageEdits.FrameOptions() { didSet { refresh() } }
    @Published var rendered: NSImage?
    @Published var renderedSize = CGSize(width: 1, height: 1)
    private let renderer = PreviewRenderer()
    private let small: CGImage

    init(_ image: LoadedImage) {
        self.image = image
        small = (try? Images.loadOriented(image.url, maxPixel: 900)) ?? image.preview
        refresh()
    }

    private func refresh() {
        let o = options, src = small
        renderer.render({ try? ImageEdits.frame(src, o) }) { [weak self] img in
            self?.renderedSize = img.size
            self?.rendered = img
        }
    }
}

struct FrameEditor: View {
    @ObservedObject var model: FrameModel
    let close: () -> Void

    var body: some View {
        EditorScaffold(primary: "Save Framed", cancel: close, save: save) {
            if let img = model.rendered {
                FittedImage(image: img, pixelSize: model.renderedSize)
            } else {
                ProgressView()
            }
        } sidebar: {
            SidebarSection("Background") { BackgroundSwatches(selection: $model.options.background) }
            SidebarSection("Canvas") {
                Picker("Canvas", selection: $model.options.ratio) {
                    ForEach(ImageEdits.CanvasRatio.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            SidebarSection("Image") {
                ValueSlider(title: "Padding", value: $model.options.padding, range: 0...0.3) { "\(Int(($0 * 100).rounded()))%" }
                ValueSlider(title: "Corner radius", value: $model.options.cornerRadius, range: 0...0.12) { "\(Int(($0 * 100).rounded()))%" }
                Toggle("Shadow", isOn: $model.options.shadow)
            }
        }
    }

    private func save() {
        let img = model.image, o = model.options
        ActionRunner.perform("Frame · \(img.url.lastPathComponent)", history: "Frame") { _ in
            [try ImageEdits.save(try ImageEdits.frame(img.full, o), beside: img.url, suffix: "framed", type: .png)]
        }
        close()
    }
}

// MARK: - Collage

final class CollageModel: ObservableObject {
    let images: [LoadedImage]
    @Published var options = ImageEdits.CollageOptions() { didSet { refresh() } }
    @Published var rendered: NSImage?
    @Published var renderedSize = CGSize(width: 1, height: 1)
    private let renderer = PreviewRenderer()

    init(_ images: [LoadedImage]) {
        self.images = images
        refresh()
    }

    private func refresh() {
        var o = options
        o.cellWidth = 360
        let small = images.map(\.preview)
        renderer.render({ try? ImageEdits.collage(small, o) }) { [weak self] img in
            self?.renderedSize = img.size
            self?.rendered = img
        }
    }
}

struct CollageEditor: View {
    @ObservedObject var model: CollageModel
    let close: () -> Void

    var body: some View {
        EditorScaffold(primary: "Save Collage", status: "\(model.images.count) images", cancel: close, save: save) {
            if let img = model.rendered {
                FittedImage(image: img, pixelSize: model.renderedSize)
            } else {
                ProgressView()
            }
        } sidebar: {
            SidebarSection("Layout") {
                Picker("Columns", selection: $model.options.columns) {
                    Text("Automatic").tag(0)
                    ForEach(1...6, id: \.self) { Text("\($0) column\($0 == 1 ? "" : "s")").tag($0) }
                }
                Picker("Images", selection: $model.options.fill) {
                    Text("Fill").tag(true)
                    Text("Fit").tag(false)
                }
                .pickerStyle(.segmented)
                ValueSlider(title: "Spacing", value: $model.options.spacing, range: 0...0.08) { "\(Int(($0 * 100).rounded()))%" }
            }
            SidebarSection("Background") { BackgroundSwatches(selection: $model.options.background, choices: Self.backgrounds) }
        }
    }

    /// Solid colors only; the collage fills its gaps with one color.
    static let backgrounds: [ImageEdits.FrameBackground] = [
        .init(id: "White", colors: [ImageEdits.RGBA(r: 1, g: 1, b: 1, a: 1)]),
        .init(id: "Black", colors: [ImageEdits.RGBA(r: 0, g: 0, b: 0, a: 1)]),
        .init(id: "Lime", colors: [ImageEdits.RGBA(r: 0.62, g: 0.84, b: 0.24, a: 1)]),
        .init(id: "Clear", colors: []),
    ]

    private func save() {
        let urls = model.images.map(\.url), o = model.options
        ActionRunner.perform("Collage · \(urls.count) images", history: "Collage") { _ in
            let imgs = try urls.map { try Images.loadOriented($0, maxPixel: 2400) }
            let out = Output.url(beside: urls[0], name: "Collage", ext: "png")
            try Images.write([try ImageEdits.collage(imgs, o)], to: out, type: .png)
            return [out]
        }
        close()
    }
}
