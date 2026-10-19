import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Video

/// Video processing behind the trim, split, speed and snapshot editors.
enum VideoEdits {
    /// Keeps the source container when AVFoundation can write it, otherwise MP4.
    static func container(for src: URL) -> (type: AVFileType, ext: String) {
        switch src.pathExtension.lowercased() {
        case "mov": (.mov, "mov")
        case "m4v": (.m4v, "m4v")
        default: (.mp4, "mp4")
        }
    }

    static func duration(_ src: URL) async throws -> Double {
        let d = try await AVURLAsset(url: src).load(.duration).seconds
        guard d.isFinite, d > 0 else { throw ConversionError("This file has no playable duration.") }
        return d
    }

    /// Export with passthrough first (lossless and fast), re-encoding only when the codecs don't allow it.
    private static func exportBest(_ asset: AVAsset, to out: URL, type: AVFileType, timeRange: CMTimeRange? = nil,
                                   passthrough: Bool = true) async throws {
        var lastError: Error = ConversionError("The export failed.")
        let presets = passthrough ? [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
                                  : [AVAssetExportPresetHighestQuality]
        for preset in presets {
            do { try await Media.export(asset, preset: preset, to: out, type: type, timeRange: timeRange); return }
            catch { lastError = error }
        }
        throw lastError
    }

    static func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600))
    }

    static func trim(_ src: URL, from start: Double, to end: Double) async throws -> URL {
        guard end - start >= 0.05 else { throw ConversionError("Keep at least a short part of the video.") }
        let (type, ext) = container(for: src)
        let out = Output.url(beside: src, name: "\(src.deletingPathExtension().lastPathComponent) trimmed", ext: ext)
        try await exportBest(AVURLAsset(url: src), to: out, type: type, timeRange: range(start, end))
        return out
    }

    /// One clip per segment between the split points, in a folder beside the source.
    static func split(_ src: URL, at points: [Double]) async throws -> [URL] {
        let total = try await duration(src)
        let cuts = points.filter { $0 > 0.05 && $0 < total - 0.05 }.sorted()
        guard !cuts.isEmpty else { throw ConversionError("Add split points inside the video, at least 0.05 seconds from either end.") }
        let bounds = [0] + cuts + [total]
        let (type, ext) = container(for: src)
        let base = src.deletingPathExtension().lastPathComponent
        let folder = Output.folder(beside: src, name: "\(base) parts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: src)
        for i in 0..<(bounds.count - 1) {
            let out = folder.appendingPathComponent("\(base) part \(i + 1)").appendingPathExtension(ext)
            try await exportBest(asset, to: out, type: type, timeRange: range(bounds[i], bounds[i + 1]))
        }
        return [folder]
    }

    /// Plays the video `factor` times faster (0.25...4), keeping the audio's pitch.
    static func speed(_ src: URL, factor: Double) async throws -> URL {
        guard (0.25...4).contains(factor) else { throw ConversionError("Choose a speed between 0.25× and 4×.") }
        let asset = AVURLAsset(url: src)
        let total = try await asset.load(.duration)
        let comp = AVMutableComposition()
        for track in try await asset.load(.tracks) where [.video, .audio].contains(track.mediaType) {
            guard let ct = comp.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try ct.insertTimeRange(CMTimeRange(start: .zero, duration: total), of: track, at: .zero)
            if track.mediaType == .video { ct.preferredTransform = try await track.load(.preferredTransform) }
        }
        comp.scaleTimeRange(CMTimeRange(start: .zero, duration: total),
                            toDuration: CMTimeMultiplyByFloat64(total, multiplier: 1 / factor))
        let (type, ext) = container(for: src)
        let label = factor == factor.rounded() ? "\(Int(factor))x" : String(format: "%.2gx", factor)
        let out = Output.url(beside: src, name: "\(src.deletingPathExtension().lastPathComponent) \(label)", ext: ext)
        try await exportBest(comp, to: out, type: type, passthrough: false)
        return out
    }

    /// Copies only the video tracks, so the result has no sound.
    static func mute(_ src: URL) async throws -> URL {
        let asset = AVURLAsset(url: src)
        let total = try await asset.load(.duration)
        let videos = try await asset.loadTracks(withMediaType: .video)
        guard !videos.isEmpty else { throw ConversionError("This file has no video track.") }
        let comp = AVMutableComposition()
        for track in videos {
            guard let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try ct.insertTimeRange(CMTimeRange(start: .zero, duration: total), of: track, at: .zero)
            ct.preferredTransform = try await track.load(.preferredTransform)
        }
        let (type, ext) = container(for: src)
        let out = Output.url(beside: src, name: "\(src.deletingPathExtension().lastPathComponent) muted", ext: ext)
        try await exportBest(comp, to: out, type: type)
        return out
    }

    /// Joins clips end to end in the order given.
    static func join(_ sources: [URL]) async throws -> URL {
        guard sources.count > 1 else { throw ConversionError("Choose at least two videos to join.") }
        let comp = AVMutableComposition()
        let video = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audio = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        for (i, src) in sources.enumerated() {
            let asset = AVURLAsset(url: src)
            let d = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: d)
            if let v = try await asset.loadTracks(withMediaType: .video).first {
                try video?.insertTimeRange(range, of: v, at: cursor)
                if i == 0 { video?.preferredTransform = try await v.load(.preferredTransform) }
            }
            if let a = try await asset.loadTracks(withMediaType: .audio).first {
                try audio?.insertTimeRange(range, of: a, at: cursor)
            }
            cursor = cursor + d
        }
        if let audio, audio.segments.isEmpty { comp.removeTrack(audio) }
        let (type, ext) = container(for: sources[0])
        let out = Output.url(beside: sources[0], name: "Joined", ext: ext)
        try await exportBest(comp, to: out, type: type)
        return out
    }

    /// Saves the exact frame at `seconds` as PNG.
    static func snapshot(_ src: URL, at seconds: Double) async throws -> URL {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: src))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let img = try await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        let stamp = String(format: "%dm%02ds", Int(seconds) / 60, Int(seconds) % 60)
        let out = Output.url(beside: src, name: "\(src.deletingPathExtension().lastPathComponent) frame \(stamp)", ext: "png")
        try Images.write([img], to: out, type: .png)
        return out
    }

    /// Evenly spaced thumbnails for the editor timeline.
    static func thumbnails(_ src: URL, count: Int, height: CGFloat) async -> [CGImage] {
        guard let total = try? await duration(src) else { return [] }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: src))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: height * 3, height: height * 2)
        var out: [CGImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: total * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            if let img = try? await gen.image(at: t).image { out.append(img) }
        }
        return out
    }
}

// MARK: - Audio

/// Audio processing behind the trim, bleep and visualizer editors and the instant audio tools.
enum AudioEdits {
    /// Whole file as deinterleaved Float32.
    static func read(_ src: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: src, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ConversionError("This file has no audio.")
        }
        try file.read(into: buf)
        return buf
    }

    static func makeBuffer(rate: Double, channels: Int, frames: Int) throws -> AVAudioPCMBuffer {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                      channels: AVAudioChannelCount(channels), interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, frames))) else {
            throw ConversionError("Could not allocate audio.")
        }
        buf.frameLength = AVAudioFrameCount(frames)
        return buf
    }

    /// Writes beside the source in the same format when AVAudioFile can encode it, otherwise as M4A.
    static func write(_ buf: AVAudioPCMBuffer, beside src: URL, suffix: String) throws -> URL {
        let rate = buf.format.sampleRate, ch = Int(buf.format.channelCount)
        let base = "\(src.deletingPathExtension().lastPathComponent) \(suffix)"
        func pcm(bigEndian: Bool) -> [String: Any] {
            [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: ch,
             AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: bigEndian,
             AVLinearPCMIsNonInterleaved: false]
        }
        let aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: min(rate, 48000),
                                  AVNumberOfChannelsKey: ch, AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue]
        let candidates: [(String, [String: Any])] = switch src.pathExtension.lowercased() {
        case "wav": [("wav", pcm(bigEndian: false))]
        case "aif", "aiff": [("aiff", pcm(bigEndian: true))]
        case "caf": [("caf", pcm(bigEndian: false))]
        case "flac": [("flac", [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: ch]), ("m4a", aac)]
        default: [("m4a", aac)]
        }
        var lastError: Error = ConversionError("Could not write the audio.")
        for (ext, settings) in candidates {
            let out = Output.url(beside: src, name: base, ext: ext)
            do {
                let file = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                try file.write(from: buf)
                return out
            } catch {
                try? FileManager.default.removeItem(at: out)
                lastError = error
            }
        }
        throw lastError
    }

    /// Copy of frames [from, to).
    static func slice(_ buf: AVAudioPCMBuffer, from: Int, to: Int) throws -> AVAudioPCMBuffer {
        let ch = Int(buf.format.channelCount)
        let n = max(0, min(to, Int(buf.frameLength)) - max(0, from))
        let out = try makeBuffer(rate: buf.format.sampleRate, channels: ch, frames: n)
        for c in 0..<ch {
            out.floatChannelData![c].update(from: buf.floatChannelData![c] + max(0, from), count: n)
        }
        return out
    }

    /// Peak level per bin across all channels, 0...1, for drawing waveforms.
    static func peaks(_ buf: AVAudioPCMBuffer, bins: Int) -> [Float] {
        let n = Int(buf.frameLength), ch = Int(buf.format.channelCount)
        guard n > 0, bins > 0 else { return [] }
        return (0..<bins).map { b in
            let lo = n * b / bins, hi = max(lo + 1, n * (b + 1) / bins)
            var peak: Float = 0
            for c in 0..<ch {
                let data = buf.floatChannelData![c]
                var i = lo
                while i < hi { peak = max(peak, abs(data[i])); i += max(1, (hi - lo) / 256) }
            }
            return min(1, peak)
        }
    }

    /// Start and end (seconds) of the audible part, ignoring quiet lead-in and tail.
    static func audibleBounds(_ buf: AVAudioPCMBuffer, threshold: Float = 0.02) -> (Double, Double) {
        let rate = buf.format.sampleRate
        let window = max(1, Int(rate / 100))   // 10 ms
        let levels = peaks(buf, bins: max(1, Int(buf.frameLength) / window))
        guard let first = levels.firstIndex(where: { $0 > threshold }),
              let last = levels.lastIndex(where: { $0 > threshold }) else { return (0, Double(buf.frameLength) / rate) }
        let secondsPerBin = Double(buf.frameLength) / rate / Double(levels.count)
        return (max(0, Double(first) * secondsPerBin - 0.05), min(Double(buf.frameLength) / rate, Double(last + 1) * secondsPerBin + 0.05))
    }

    static func trim(_ src: URL, from start: Double, to end: Double) throws -> URL {
        let buf = try read(src)
        let rate = buf.format.sampleRate
        guard end - start >= 0.05 else { throw ConversionError("Keep at least a short part of the audio.") }
        return try write(slice(buf, from: Int(start * rate), to: Int(end * rate)), beside: src, suffix: "trimmed")
    }

    static func trimSilence(_ src: URL) throws -> URL {
        let buf = try read(src)
        let (start, end) = audibleBounds(buf)
        let rate = buf.format.sampleRate
        return try write(slice(buf, from: Int(start * rate), to: Int(end * rate)), beside: src, suffix: "trimmed")
    }

    /// Replaces each range with a 1 kHz tone, or silence when `tone` is false. Edges fade over 5 ms to avoid clicks.
    static func bleep(_ src: URL, ranges: [ClosedRange<Double>], tone: Bool) throws -> URL {
        guard !ranges.isEmpty else { throw ConversionError("Add at least one bleep range.") }
        let buf = try read(src)
        let rate = buf.format.sampleRate, n = Int(buf.frameLength), ch = Int(buf.format.channelCount)
        let fade = Int(rate * 0.005)
        for r in ranges {
            let lo = max(0, Int(r.lowerBound * rate)), hi = min(n, Int(r.upperBound * rate))
            guard hi > lo else { continue }
            for c in 0..<ch {
                let data = buf.floatChannelData![c]
                for i in lo..<hi {
                    let edge = Float(min(1, Double(min(i - lo, hi - 1 - i)) / Double(max(1, fade))))
                    let beep: Float = tone ? 0.3 * sin(2 * .pi * 1000 * Float(i) / Float(rate)) : 0
                    data[i] = data[i] * (1 - edge) + beep * edge
                }
            }
        }
        return try write(buf, beside: src, suffix: "bleeped")
    }

    /// Scales so the loudest sample peaks at -1 dBFS.
    static func normalize(_ src: URL) throws -> URL {
        let buf = try read(src)
        let peak = peaks(buf, bins: 1).first ?? 0
        guard peak > 0.0001 else { throw ConversionError("This audio is silent.") }
        let gain = 0.891 / peak
        for c in 0..<Int(buf.format.channelCount) {
            let data = buf.floatChannelData![c]
            for i in 0..<Int(buf.frameLength) { data[i] *= gain }
        }
        return try write(buf, beside: src, suffix: "normalized")
    }

    /// Mono mixes all channels together; stereo copies a mono channel to both sides.
    static func channels(_ src: URL, mono: Bool) throws -> URL {
        let buf = try read(src)
        let ch = Int(buf.format.channelCount), n = Int(buf.frameLength)
        if mono && ch == 1 { throw ConversionError("This audio is already mono.") }
        if !mono && ch == 2 { throw ConversionError("This audio is already stereo.") }
        let out = try makeBuffer(rate: buf.format.sampleRate, channels: mono ? 1 : 2, frames: n)
        if mono {
            let dst = out.floatChannelData![0]
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<ch { sum += buf.floatChannelData![c][i] }
                dst[i] = sum / Float(ch)
            }
        } else {
            for c in 0..<2 {
                out.floatChannelData![c].update(from: buf.floatChannelData![min(c, ch - 1)], count: n)
            }
        }
        return try write(out, beside: src, suffix: mono ? "mono" : "stereo")
    }

    // MARK: Visualizer

    enum VisualizerStyle: String, CaseIterable, Identifiable {
        case bars, wave, circle
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    struct VisualizerOptions: Equatable {
        var style = VisualizerStyle.bars
        var color = ImageEdits.RGBA(r: 0.62, g: 0.84, b: 0.24, a: 1)
        var dark = true
        var showTitle = true
    }

    /// Draws one visualizer frame. `levels` are 0...1 per band.
    static func drawVisualizer(_ levels: [Float], in ctx: CGContext, size: CGSize, options o: VisualizerOptions, title: String?) {
        let bg: CGColor = o.dark ? CGColor(srgbRed: 0.06, green: 0.07, blue: 0.06, alpha: 1) : CGColor(gray: 0.97, alpha: 1)
        ctx.setFillColor(bg)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(o.color.cgColor)
        ctx.setStrokeColor(o.color.cgColor)
        let midY = size.height * (o.showTitle ? 0.56 : 0.5)
        let span = size.width * 0.8, x0 = size.width * 0.1
        switch o.style {
        case .bars:
            let slot = span / CGFloat(levels.count), w = slot * 0.62
            for (i, l) in levels.enumerated() {
                let h = max(w, CGFloat(l) * size.height * 0.55)
                let r = CGRect(x: x0 + CGFloat(i) * slot + (slot - w) / 2, y: midY - h / 2, width: w, height: h)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
            }
            ctx.fillPath()
        case .wave:
            ctx.setLineWidth(size.height * 0.008)
            ctx.setLineJoin(.round)
            for sign in [1.0, -1.0] {
                ctx.beginPath()
                for (i, l) in levels.enumerated() {
                    let p = CGPoint(x: x0 + span * CGFloat(i) / CGFloat(max(1, levels.count - 1)),
                                    y: midY + CGFloat(sign) * CGFloat(l) * size.height * 0.26)
                    i == 0 ? ctx.move(to: p) : ctx.addLine(to: p)
                }
                ctx.strokePath()
            }
        case .circle:
            let r0 = size.height * 0.16, c = CGPoint(x: size.width / 2, y: midY)
            ctx.setLineWidth(size.height * 0.012)
            ctx.setLineCap(.round)
            for (i, l) in levels.enumerated() {
                let a = CGFloat(i) / CGFloat(levels.count) * 2 * .pi
                let r1 = r0 + max(2, CGFloat(l) * size.height * 0.2)
                ctx.strokeLineSegments(between: [CGPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0),
                                                 CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1)])
            }
        }
        if o.showTitle, let title {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size.height * 0.045, weight: .semibold),
                .foregroundColor: o.dark ? NSColor.white : NSColor.black,
            ]
            let s = title as NSString, sz = s.size(withAttributes: attrs)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            s.draw(at: CGPoint(x: (size.width - sz.width) / 2, y: size.height * 0.12), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Band levels for the window of audio around `time`.
    static func levels(_ buf: AVAudioPCMBuffer, at time: Double, bands: Int) -> [Float] {
        let rate = buf.format.sampleRate, n = Int(buf.frameLength)
        let window = Int(rate / 15)
        let start = max(0, min(n - 1, Int(time * rate) - window / 2))
        let data = buf.floatChannelData![0]
        return (0..<bands).map { b in
            // Each band looks at a different slice of the window, so bars move independently.
            let lo = start + window * b / bands, hi = min(n, start + window * (b + 1) / bands)
            guard hi > lo else { return 0 }
            var sum: Float = 0
            for i in lo..<hi { sum += data[i] * data[i] }
            return min(1, sqrt(sum / Float(hi - lo)) * 3.2)
        }
    }

    /// Renders an MP4 of the visualizer with the original audio.
    static func visualize(_ src: URL, options: VisualizerOptions, progress: ((Double) -> Void)? = nil) async throws -> URL {
        let buf = try read(src)
        let seconds = Double(buf.frameLength) / buf.format.sampleRate
        guard seconds <= 20 * 60 else { throw ConversionError("Choose audio shorter than 20 minutes.") }
        let size = CGSize(width: 1280, height: 720), fps = 30
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ConversionError("Could not start the video.") }
        writer.startSession(atSourceTime: .zero)
        let title = src.deletingPathExtension().lastPathComponent
        let frames = Int(seconds * Double(fps)) + 1
        var smoothed = [Float](repeating: 0, count: 48)
        for f in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess,
                  let pb else { throw ConversionError("Could not allocate a video frame.") }
            CVPixelBufferLockBaseAddress(pb, [])
            let raw = levels(buf, at: Double(f) / Double(fps), bands: smoothed.count)
            for i in raw.indices { smoothed[i] = max(raw[i], smoothed[i] * 0.82) }   // fast attack, slow decay
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height),
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                drawVisualizer(smoothed, in: ctx, size: size, options: options, title: title)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
            if f % 30 == 0 { progress?(Double(f) / Double(frames)) }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ConversionError("Could not finish the video.") }

        // Mux the rendered frames with the original audio.
        let comp = AVMutableComposition()
        let video = AVURLAsset(url: tmp), audio = AVURLAsset(url: src)
        let length = CMTime(seconds: seconds, preferredTimescale: 600)
        if let v = try await video.loadTracks(withMediaType: .video).first {
            try comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
                .insertTimeRange(CMTimeRange(start: .zero, duration: min(length, try await video.load(.duration))), of: v, at: .zero)
        }
        if let a = try await audio.loadTracks(withMediaType: .audio).first {
            try comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
                .insertTimeRange(CMTimeRange(start: .zero, duration: length), of: a, at: .zero)
        }
        let out = Output.url(beside: src, name: "\(title) visualizer", ext: "mp4")
        try await Media.export(comp, preset: AVAssetExportPresetHighestQuality, to: out, type: .mp4)
        return out
    }
}
