import AppKit
import AVFoundation
import AVKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

func timecode(_ s: Double) -> String {
    guard s.isFinite else { return "0:00.0" }
    let t = max(0, s)
    return String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
}

// MARK: - Timeline

final class TimelineDrag: ObservableObject {
    enum Target { case start, end, scrub, span }
    @Published var span: ClosedRange<Double>?
    @Published var target: Target?
}

/// Scrubbable strip with an optional trim range, markers, highlighted spans and a playhead.
/// One gesture handles everything: where a drag begins decides whether it moves a trim handle, scrubs or marks a span.
struct Timeline<Background: View>: View {
    let duration: Double
    let current: Double
    var start: Binding<Double>? = nil
    var end: Binding<Double>? = nil
    var markers: [Double] = []
    var spans: [ClosedRange<Double>] = []
    let seek: (Double) -> Void
    /// When set, dragging across the strip creates a span instead of scrubbing.
    var onSpan: ((ClosedRange<Double>) -> Void)? = nil
    let background: Background
    @StateObject private var drag = TimelineDrag()

    /// Keeps handles inside the strip's bounds, so the ones at either end are as easy to grab as the rest.
    private let inset: CGFloat = 8
    /// How far from a handle a drag may start and still grab it.
    private let grabRadius: CGFloat = 16

    init(duration: Double, current: Double, start: Binding<Double>? = nil, end: Binding<Double>? = nil,
         markers: [Double] = [], spans: [ClosedRange<Double>] = [], seek: @escaping (Double) -> Void,
         onSpan: ((ClosedRange<Double>) -> Void)? = nil, @ViewBuilder background: () -> Background) {
        self.duration = duration
        self.current = current
        self.start = start
        self.end = end
        self.markers = markers
        self.spans = spans
        self.seek = seek
        self.onSpan = onSpan
        self.background = background()
    }

    var body: some View {
        GeometryReader { g in
            let w = max(1, g.size.width - 2 * inset), h = g.size.height
            let x: (Double) -> CGFloat = { t in inset + (duration > 0 ? CGFloat(t / duration) * w : 0) }
            let time: (CGFloat) -> Double = { px in duration * Double(min(max((px - inset) / w, 0), 1)) }
            ZStack(alignment: .topLeading) {
                background
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .offset(x: inset)
                ForEach(Array((spans + (drag.span.map { [$0] } ?? [])).enumerated()), id: \.offset) { _, s in
                    Rectangle().fill(Color.red.opacity(0.4))
                        .frame(width: max(2, x(s.upperBound) - x(s.lowerBound)), height: h)
                        .offset(x: x(s.lowerBound))
                }
                if let start, let end {
                    Color.black.opacity(0.55).frame(width: max(0, x(start.wrappedValue) - inset), height: h).offset(x: inset)
                    Color.black.opacity(0.55).frame(width: max(0, inset + w - x(end.wrappedValue)), height: h).offset(x: x(end.wrappedValue))
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: Brand.lime), lineWidth: 3)
                        .frame(width: max(6, x(end.wrappedValue) - x(start.wrappedValue)), height: h)
                        .offset(x: x(start.wrappedValue))
                }
                ForEach(markers, id: \.self) { m in
                    Rectangle().fill(Color.yellow).frame(width: 2, height: h).offset(x: x(m) - 1)
                }
                Rectangle().fill(Color.white).frame(width: 2, height: h + 10).offset(x: x(current) - 1, y: -5)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                if let start, let end {
                    handle(active: drag.target == .start).position(x: x(start.wrappedValue), y: h / 2)
                    handle(active: drag.target == .end).position(x: x(end.wrappedValue), y: h / 2)
                }
            }
            .frame(width: g.size.width, height: h, alignment: .topLeading)
            .allowsHitTesting(false)
            .coordinateSpace(name: "timeline")
            .overlay(
                // The grab area reaches a little past both ends, so a handle at the edge is easy to catch.
                Color.clear
                    .contentShape(Rectangle())
                    .padding(.horizontal, -grabRadius)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                        .onChanged { v in
                            if drag.target == nil { drag.target = target(at: v.startLocation.x, x: x) }
                            switch drag.target {
                            case .start:
                                if let start, let end { start.wrappedValue = min(time(v.location.x), end.wrappedValue - 0.1); seek(start.wrappedValue) }
                            case .end:
                                if let start, let end { end.wrappedValue = max(time(v.location.x), start.wrappedValue + 0.1); seek(end.wrappedValue) }
                            case .span, .scrub:
                                if onSpan != nil, abs(v.translation.width) > 3 {
                                    drag.target = .span
                                    let a = time(v.startLocation.x), b = time(v.location.x)
                                    drag.span = min(a, b)...max(a, b)
                                } else {
                                    seek(time(v.location.x))
                                }
                            case nil: break
                            }
                        }
                        .onEnded { _ in
                            if drag.target == .span, let s = drag.span, s.upperBound - s.lowerBound > 0.05 { onSpan?(s) }
                            drag.span = nil
                            drag.target = nil
                        })
            )
        }
    }

    /// The nearer trim handle within reach of `px`, otherwise scrubbing.
    private func target(at px: CGFloat, x: (Double) -> CGFloat) -> TimelineDrag.Target {
        guard let start, let end else { return .scrub }
        let ds = abs(px - x(start.wrappedValue)), de = abs(px - x(end.wrappedValue))
        guard min(ds, de) <= grabRadius else { return .scrub }
        // When the handles overlap, pick the one whose direction the drag can still go.
        if abs(ds - de) < 1 { return px >= x(end.wrappedValue) ? .end : .start }
        return ds < de ? .start : .end
    }

    private func handle(active: Bool) -> some View {
        Capsule().fill(active ? Color(nsColor: Brand.lime) : Color.white)
            .frame(width: 12, height: 32)
            .overlay(Capsule().strokeBorder(Color(nsColor: Brand.limeDeep), lineWidth: 2))
            .shadow(color: .black.opacity(0.4), radius: 2)
    }
}

struct Waveform: View {
    let peaks: [Float]
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black.opacity(0.75)))
            guard !peaks.isEmpty else { return }
            let step = size.width / CGFloat(peaks.count)
            var path = Path()
            for (i, p) in peaks.enumerated() {
                let h = max(1, CGFloat(p) * size.height * 0.92)
                path.addRect(CGRect(x: CGFloat(i) * step, y: (size.height - h) / 2, width: max(1, step * 0.7), height: h))
            }
            ctx.fill(path, with: .color(Color(nsColor: Brand.lime)))
        }
    }
}

// MARK: - Video

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

@MainActor
final class VideoModel: ObservableObject {
    enum Mode { case trim, split, speed, snapshot }
    let url: URL
    let mode: Mode
    let player: AVPlayer
    @Published var duration = 0.0
    @Published var current = 0.0
    @Published var start = 0.0
    @Published var end = 0.0
    @Published var markers: [Double] = []
    @Published var thumbs: [CGImage] = []
    @Published var playing = false
    @Published var speed = 2.0 { didSet { if player.rate != 0 { player.rate = Float(speed) } } }
    private var observer: Any?

    init(url: URL, mode: Mode) {
        self.url = url
        self.mode = mode
        player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        Task {
            let d = (try? await VideoEdits.duration(url)) ?? 0
            duration = d
            end = d
            thumbs = await VideoEdits.thumbnails(url, count: 14, height: 56)
        }
    }

    private func tick(_ t: Double) {
        current = t
        if mode == .trim, player.rate != 0, t >= end { seek(start) }
        playing = player.rate != 0
    }

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
        } else {
            if mode == .trim, current < start || current >= end - 0.05 { seek(start) }
            if current >= duration - 0.05 { seek(0) }
            player.rate = Float(mode == .speed ? speed : 1)
        }
        playing = player.rate != 0
    }

    func seek(_ t: Double) {
        let c = min(max(0, t), duration)
        current = c
        player.seek(to: CMTime(seconds: c, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func addMarker() {
        guard current > 0.05, current < duration - 0.05,
              !markers.contains(where: { abs($0 - current) < 0.05 }) else { return }
        markers.append(current)
        markers.sort()
    }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }
}

struct VideoEditor: View {
    @ObservedObject var model: VideoModel
    let close: () -> Void

    var body: some View {
        EditorScaffold(primary: primaryLabel, canSave: canSave, status: status, cancel: close, save: save) {
            VStack(spacing: 12) {
                PlayerView(player: model.player)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 12) {
                    Button(action: model.togglePlay) {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 18)
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    Text("\(timecode(model.current)) / \(timecode(model.duration))").monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                }
                Timeline(duration: model.duration, current: model.current,
                         start: model.mode == .trim ? $model.start : nil, end: model.mode == .trim ? $model.end : nil,
                         markers: model.markers, seek: model.seek) {
                    HStack(spacing: 0) {
                        ForEach(model.thumbs.indices, id: \.self) { i in
                            Image(nsImage: NSImage(cgImage: model.thumbs[i], size: .zero))
                                .resizable().aspectRatio(contentMode: .fill)
                                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                        }
                    }
                    .background(Color.black)
                }
                .frame(height: 56)
            }
            .padding(16)
        } sidebar: {
            switch model.mode {
            case .trim:
                SidebarSection("Range") {
                    LabeledContent("Start", value: timecode(model.start)).monospacedDigit()
                    LabeledContent("End", value: timecode(model.end)).monospacedDigit()
                    LabeledContent("Length", value: timecode(model.end - model.start)).monospacedDigit()
                    HStack {
                        Button("Set Start") { model.start = min(model.current, model.end - 0.1) }
                        Button("Set End") { model.end = max(model.current, model.start + 0.1) }
                    }
                }
                Text("Drag the ends to trim. Playback loops inside the range.").font(.caption).foregroundStyle(.secondary)
            case .split:
                SidebarSection("Split points") {
                    Button { model.addMarker() } label: { Label("Split at Playhead", systemImage: "plus") }
                        .keyboardShortcut("s", modifiers: [])
                    markerList
                }
                Text("Each part is saved as its own clip in a folder.").font(.caption).foregroundStyle(.secondary)
            case .snapshot:
                SidebarSection("Frames") {
                    Button { model.addMarker() } label: { Label("Add This Frame", systemImage: "camera") }
                        .keyboardShortcut("s", modifiers: [])
                    markerList
                }
                Text("Scrub to a frame and add it. All frames are saved as PNG.").font(.caption).foregroundStyle(.secondary)
            case .speed:
                SidebarSection("Speed") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach([0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4], id: \.self) { s in
                            Button(speedLabel(s)) { model.speed = s }
                                .buttonStyle(.bordered)
                                .tint(model.speed == s ? Color(nsColor: Brand.limeDeep) : nil)
                        }
                    }
                    ValueSlider(title: "Custom", value: $model.speed, range: 0.25...4) { speedLabel($0) }
                    LabeledContent("New length", value: timecode(model.duration / model.speed)).monospacedDigit()
                }
                Text("Press play to preview at this speed. Audio keeps its pitch.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { model.stop() }
    }

    private var markerList: some View {
        ForEach(model.markers, id: \.self) { m in
            HStack {
                Text(timecode(m)).monospacedDigit()
                Spacer()
                Button { model.seek(m) } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.borderless)
                Button { model.markers.removeAll { $0 == m } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
            }
        }
    }

    private func speedLabel(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s))×" : String(format: "%g×", (s * 100).rounded() / 100)
    }

    private var primaryLabel: String {
        switch model.mode {
        case .trim: "Save Trimmed"
        case .split: "Save \(model.markers.count + 1) Parts"
        case .speed: "Save at \(speedLabel(model.speed))"
        case .snapshot: model.markers.count == 1 ? "Save Frame" : "Save \(model.markers.count) Frames"
        }
    }

    private var canSave: Bool {
        switch model.mode {
        case .trim: model.duration > 0 && (model.start > 0.01 || model.end < model.duration - 0.01)
        case .split, .snapshot: !model.markers.isEmpty
        case .speed: model.duration > 0 && abs(model.speed - 1) > 0.01
        }
    }

    private var status: String {
        switch model.mode {
        case .trim: "Keeping \(timecode(model.end - model.start)) of \(timecode(model.duration))"
        case .split: model.markers.isEmpty ? "Press S or the button to add a split at the playhead." : "\(model.markers.count + 1) parts"
        case .snapshot: model.markers.isEmpty ? "Add a frame to save." : "\(model.markers.count) frame\(model.markers.count == 1 ? "" : "s")"
        case .speed: "\(timecode(model.duration)) → \(timecode(model.duration / model.speed))"
        }
    }

    private func save() {
        let url = model.url, start = model.start, end = model.end, markers = model.markers, speed = model.speed
        let name = url.lastPathComponent
        switch model.mode {
        case .trim:
            ActionRunner.perform("Trim · \(name)", history: "Trim") { _ in [try await VideoEdits.trim(url, from: start, to: end)] }
        case .split:
            ActionRunner.perform("Split · \(name)", history: "Split") { _ in try await VideoEdits.split(url, at: markers) }
        case .speed:
            ActionRunner.perform("Speed · \(name)", history: "Speed") { _ in [try await VideoEdits.speed(url, factor: speed)] }
        case .snapshot:
            ActionRunner.perform("Snapshot · \(name)", history: "Snapshot") { progress in
                var out: [URL] = []
                for (i, m) in markers.enumerated() {
                    out.append(try await VideoEdits.snapshot(url, at: m))
                    progress(Double(i + 1) / Double(markers.count))
                }
                return out
            }
        }
        model.stop()
        close()
    }
}

// MARK: - Audio

@MainActor
final class AudioModel: ObservableObject {
    enum Mode { case trim, bleep, visualize }
    let url: URL
    let mode: Mode
    @Published var peaks: [Float] = []
    @Published var duration = 0.0
    @Published var current = 0.0
    @Published var start = 0.0
    @Published var end = 0.0
    @Published var bleeps: [ClosedRange<Double>] = []
    @Published var tone = true
    @Published var playing = false
    @Published var visualizer = AudioEdits.VisualizerOptions() { didSet { renderPreview() } }
    @Published var preview: NSImage?
    @Published var loadError: String?
    private var buffer: AVAudioPCMBuffer?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    init(url: URL, mode: Mode) {
        self.url = url
        self.mode = mode
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> (AVAudioPCMBuffer, [Float]) in
                    let buf = try AudioEdits.read(url)
                    return (buf, AudioEdits.peaks(buf, bins: 900))
                }
            }.value
            switch result {
            case .success(let (buf, peaks)): self?.loaded(buf, peaks)
            case .failure(let error): self?.loadError = error.localizedDescription
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func loaded(_ buf: AVAudioPCMBuffer, _ peaks: [Float]) {
        buffer = buf
        self.peaks = peaks
        duration = Double(buf.frameLength) / buf.format.sampleRate
        end = duration
        renderPreview()
    }

    private func tick() {
        guard let player else { return }
        current = player.currentTime
        if mode == .trim, player.isPlaying, current >= end { player.currentTime = start }
        playing = player.isPlaying
    }

    func togglePlay() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
        } else {
            if mode == .trim, current < start || current >= end - 0.05 { player.currentTime = start }
            player.play()
        }
        playing = player.isPlaying
    }

    func seek(_ t: Double) {
        current = min(max(0, t), duration)
        player?.currentTime = current
    }

    func trimSilence() {
        guard let buffer else { return }
        (start, end) = AudioEdits.audibleBounds(buffer)
        seek(start)
    }

    func renderPreview() {
        guard mode == .visualize, let buffer else { return }
        let size = CGSize(width: 960, height: 540)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let levels = AudioEdits.levels(buffer, at: duration * 0.35, bands: 48)
        AudioEdits.drawVisualizer(levels, in: ctx, size: size, options: visualizer, title: url.deletingPathExtension().lastPathComponent)
        if let img = ctx.makeImage() { preview = NSImage(cgImage: img, size: size) }
    }

    func stop() {
        player?.stop()
        timer?.invalidate()
        timer = nil
    }
}

struct AudioEditor: View {
    @ObservedObject var model: AudioModel
    let close: () -> Void

    var body: some View {
        EditorScaffold(primary: model.mode == .bleep ? "Save Bleeped" : "Save Trimmed", canSave: canSave, status: status,
                       cancel: close, save: save) {
            VStack(spacing: 14) {
                Spacer()
                if let error = model.loadError {
                    Text(error).foregroundStyle(.secondary)
                }
                Timeline(duration: model.duration, current: model.current,
                         start: model.mode == .trim ? $model.start : nil, end: model.mode == .trim ? $model.end : nil,
                         spans: model.bleeps, seek: model.seek,
                         onSpan: model.mode == .bleep ? { model.bleeps.append($0) } : nil) {
                    Waveform(peaks: model.peaks)
                }
                .frame(height: 140)
                HStack(spacing: 12) {
                    Button(action: model.togglePlay) {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 18)
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    Text("\(timecode(model.current)) / \(timecode(model.duration))").monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer()
            }
            .padding(24)
        } sidebar: {
            if model.mode == .trim {
                SidebarSection("Range") {
                    LabeledContent("Start", value: timecode(model.start)).monospacedDigit()
                    LabeledContent("End", value: timecode(model.end)).monospacedDigit()
                    LabeledContent("Length", value: timecode(model.end - model.start)).monospacedDigit()
                    HStack {
                        Button("Set Start") { model.start = min(model.current, model.end - 0.1) }
                        Button("Set End") { model.end = max(model.current, model.start + 0.1) }
                    }
                }
                Button { model.trimSilence() } label: { Label("Trim Silent Ends", systemImage: "waveform.badge.minus") }
                Text("Drag the ends to trim. Playback loops inside the range.").font(.caption).foregroundStyle(.secondary)
            } else {
                SidebarSection("Replace with") {
                    Picker("Replace with", selection: $model.tone) {
                        Text("Bleep").tag(true)
                        Text("Silence").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                SidebarSection("Sections") {
                    ForEach(Array(model.bleeps.enumerated()), id: \.offset) { i, r in
                        HStack {
                            Text("\(timecode(r.lowerBound)) – \(timecode(r.upperBound))").monospacedDigit()
                            Spacer()
                            Button { model.bleeps.remove(at: i) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                        }
                    }
                    Button("Bleep Entire Audio") { model.bleeps = [0...model.duration] }
                }
                Text("Drag across the waveform to mark a section. Click to move the playhead.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { model.stop() }
    }

    private var canSave: Bool {
        guard model.duration > 0 else { return false }
        return model.mode == .bleep ? !model.bleeps.isEmpty : (model.start > 0.01 || model.end < model.duration - 0.01)
    }

    private var status: String {
        if model.mode == .bleep {
            return model.bleeps.isEmpty ? "Add at least one section." : "\(model.bleeps.count) section\(model.bleeps.count == 1 ? "" : "s")"
        }
        return "Keeping \(timecode(model.end - model.start)) of \(timecode(model.duration))"
    }

    private func save() {
        let url = model.url, start = model.start, end = model.end, bleeps = model.bleeps, tone = model.tone
        if model.mode == .bleep {
            ActionRunner.perform("Bleep · \(url.lastPathComponent)", history: "Bleep") { _ in
                [try AudioEdits.bleep(url, ranges: bleeps, tone: tone)]
            }
        } else {
            ActionRunner.perform("Trim · \(url.lastPathComponent)", history: "Trim") { _ in
                [try AudioEdits.trim(url, from: start, to: end)]
            }
        }
        model.stop()
        close()
    }
}

struct VisualizerEditor: View {
    @ObservedObject var model: AudioModel
    let close: () -> Void
    private let colors: [ImageEdits.RGBA] = [ImageEdits.RGBA(r: 0.62, g: 0.84, b: 0.24, a: 1)] + ImageEdits.RGBA.palette

    var body: some View {
        EditorScaffold(primary: "Create Video", canSave: model.duration > 0, status: "1280 × 720 MP4 · \(timecode(model.duration))",
                       cancel: close, save: save) {
            if let img = model.preview {
                FittedImage(image: img, pixelSize: CGSize(width: 1280, height: 720))
            } else {
                ProgressView()
            }
        } sidebar: {
            SidebarSection("Style") {
                Picker("Style", selection: $model.visualizer.style) {
                    ForEach(AudioEdits.VisualizerStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            SidebarSection("Color") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 8), count: 5), alignment: .leading, spacing: 8) {
                    ForEach(colors.indices, id: \.self) { i in
                        let c = colors[i]
                        Circle().fill(c.color)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25)))
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: model.visualizer.color == c ? 2.5 : 0).padding(-3))
                            .frame(width: 22, height: 22)
                            .onTapGesture { model.visualizer.color = c }
                    }
                }
            }
            Toggle("Dark background", isOn: $model.visualizer.dark)
            Toggle("Show title", isOn: $model.visualizer.showTitle)
            Text("Renders a video of the audio for sharing where audio files aren't accepted.").font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { model.stop() }
    }

    private func save() {
        let url = model.url, options = model.visualizer
        ActionRunner.perform("Visualizer · \(url.lastPathComponent)", history: "Visualizer") { progress in
            [try await AudioEdits.visualize(url, options: options, progress: progress)]
        }
        model.stop()
        close()
    }
}

// MARK: - PDF organizer

@MainActor
final class OrganizerModel: ObservableObject {
    let url: URL
    let document: PDFDocument
    @Published var pages: [PDFEdits.PageRef]
    @Published var selection: Set<UUID> = []
    var dragging: UUID?
    private var thumbCache: [Int: NSImage] = [:]

    init(url: URL, document: PDFDocument) {
        self.url = url
        self.document = document
        pages = (0..<document.pageCount).map { PDFEdits.PageRef(index: $0) }
    }

    func thumbnail(_ index: Int) -> NSImage {
        if let t = thumbCache[index] { return t }
        let t = document.page(at: index)?.thumbnail(of: CGSize(width: 240, height: 300), for: .cropBox) ?? NSImage()
        thumbCache[index] = t
        return t
    }

    func rotate(by degrees: Int) {
        for i in pages.indices where selection.contains(pages[i].id) { pages[i].rotation = (pages[i].rotation + degrees + 360) % 360 }
    }

    func deleteSelected() {
        pages.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    func move(_ id: UUID, before target: UUID) {
        guard id != target, let from = pages.firstIndex(where: { $0.id == id }),
              let to = pages.firstIndex(where: { $0.id == target }) else { return }
        let page = pages.remove(at: from)
        pages.insert(page, at: to)
    }

    func tap(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }
}

struct PageDropDelegate: DropDelegate {
    let target: UUID
    let model: OrganizerModel

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let dragging = model.dragging else { return }
            withAnimation(.easeInOut(duration: 0.15)) { model.move(dragging, before: target) }
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { model.dragging = nil }
        return true
    }
}

struct OrganizerEditor: View {
    @ObservedObject var model: OrganizerModel
    let close: () -> Void

    var body: some View {
        EditorScaffold(primary: "Save PDF", canSave: !model.pages.isEmpty,
                       status: "\(model.pages.count) of \(model.document.pageCount) pages", cancel: close, save: save) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 14)], spacing: 16) {
                    ForEach(model.pages) { ref in
                        let selected = model.selection.contains(ref.id)
                        VStack(spacing: 6) {
                            Image(nsImage: model.thumbnail(ref.index))
                                .resizable().aspectRatio(contentMode: .fit)
                                .frame(width: 112, height: 140)
                                .rotationEffect(.degrees(Double(ref.rotation)))
                                .frame(width: 140, height: 140)
                                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                            Text("Page \(ref.index + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(selected ? Color(nsColor: Brand.lime).opacity(0.3) : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(selected ? Color(nsColor: Brand.limeDeep) : .clear, lineWidth: 2))
                        .contentShape(Rectangle())
                        .onTapGesture { model.tap(ref.id) }
                        .onDrag {
                            model.dragging = ref.id
                            return NSItemProvider(object: ref.id.uuidString as NSString)
                        }
                        .onDrop(of: [UTType.text], delegate: PageDropDelegate(target: ref.id, model: model))
                    }
                }
                .padding(20)
            }
            .onDeleteCommand { model.deleteSelected() }
        } sidebar: {
            SidebarSection("Selected pages") {
                HStack {
                    Button { model.rotate(by: -90) } label: { Image(systemName: "rotate.left") }.help("Rotate left")
                    Button { model.rotate(by: 90) } label: { Image(systemName: "rotate.right") }.help("Rotate right")
                    Button(role: .destructive) { model.deleteSelected() } label: { Image(systemName: "trash") }.help("Delete")
                }
                .disabled(model.selection.isEmpty)
                Button("Select All") { model.selection = Set(model.pages.map(\.id)) }
                Button("Reverse Order") { model.pages.reverse() }
            }
            Text("Drag pages to reorder them. ⌘-click to select several. Press Delete to remove the selection.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        let url = model.url, pages = model.pages
        ActionRunner.perform("Organize · \(url.lastPathComponent)", history: "Organize") { _ in
            [try PDFEdits.organize(url, pages: pages)]
        }
        close()
    }
}
