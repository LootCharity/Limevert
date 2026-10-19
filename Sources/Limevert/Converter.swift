import AppKit
import AVFoundation
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers

struct ConversionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Helpers shared by conversions and tools: output naming and subprocesses.
enum Output {
    /// A free path beside `source`, e.g. "Photo.png", then "Photo 2.png".
    static func url(beside source: URL, name: String? = nil, ext: String) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = name ?? source.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    static func folder(beside source: URL, name: String) -> URL {
        let dir = source.deletingLastPathComponent()
        var candidate = dir.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConversionError(msg?.isEmpty == false ? msg! : "\(URL(fileURLWithPath: tool).lastPathComponent) failed.")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum Converter {
    static func convert(_ src: URL, to fmt: OutputFormat) async throws -> [URL] {
        switch FileKind.of(src) {
        case .image: return [try Images.convert(src, to: fmt)]
        case .video:
            if fmt == .animatedGIF { return [try await Media.gif(from: src)] }
            return [try await Media.exportVideo(src, to: fmt)]
        case .audio: return [try Media.convertAudio(src, to: fmt)]
        case .pdf: return try PDFs.convert(src, to: fmt)
        case .document: return [try await Documents.convert(src, to: fmt)]
        case .subtitle: return [try Subtitles.convert(src, to: fmt)]
        default: throw ConversionError("This file type is not supported.")
        }
    }
}

// MARK: - Images

enum Images {
    /// Orientation-corrected image, so outputs never depend on EXIF orientation.
    static func loadOriented(_ url: URL, maxPixel: Int? = nil) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ConversionError("Could not read the image.") }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 4096
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 4096
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel ?? max(w, h),
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ConversionError("Could not read the image.")
        }
        return img
    }

    static func write(_ images: [CGImage], to url: URL, type: UTType, quality: Double? = nil) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil) else {
            throw ConversionError("ImageIO could not create the output image.")
        }
        var props: [CFString: Any] = [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        for img in images { CGImageDestinationAddImage(dest, img, props as CFDictionary) }
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: url)
            throw ConversionError("ImageIO could not finish the image.")
        }
    }

    static func convert(_ src: URL, to fmt: OutputFormat) throws -> URL {
        if fmt == .imagePDF { return try toPDF([src], output: Output.url(beside: src, ext: "pdf")) }
        guard let type = fmt.imageType else { throw ConversionError("Conversion to \(fmt.label) is unavailable.") }
        let out = Output.url(beside: src, ext: fmt.fileExtension)
        var img = try loadOriented(src, maxPixel: fmt == .icns ? 1024 : nil)
        if fmt == .icns {
            // ICNS holds one square rendition per standard icon size.
            let sizes = [16, 32, 64, 128, 256, 512, 1024]
            try write(try sizes.map { try squared(img, side: $0) }, to: out, type: type)
            return out
        }
        if [.jpeg, .bmp].contains(fmt) { img = flattened(img) }
        let quality = [.jpeg, .heic, .avif, .webp].contains(fmt) ? Settings.shared.imageQuality : nil
        try write([img], to: out, type: type, quality: quality)
        return out
    }

    static func toPDF(_ sources: [URL], output: URL) throws -> URL {
        let doc = PDFDocument()
        for src in sources {
            let img = try loadOriented(src)
            let ns = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
            guard let page = PDFPage(image: ns) else { throw ConversionError("Could not create the PDF.") }
            doc.insert(page, at: doc.pageCount)
        }
        guard doc.write(to: output) else { throw ConversionError("Could not create the PDF.") }
        return output
    }

    /// Draws over white; for formats without alpha.
    static func flattened(_ img: CGImage) -> CGImage {
        guard img.alphaInfo != .none, img.alphaInfo != .noneSkipLast, img.alphaInfo != .noneSkipFirst,
              let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return img }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage() ?? img
    }

    static func squared(_ img: CGImage, side: Int) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConversionError("Could not create the edited image.") }
        let scale = CGFloat(side) / CGFloat(max(img.width, img.height))
        let w = CGFloat(img.width) * scale, h = CGFloat(img.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2, width: w, height: h))
        guard let out = ctx.makeImage() else { throw ConversionError("Could not create the edited image.") }
        return out
    }

    static func scaled(_ img: CGImage, by factor: CGFloat) throws -> CGImage {
        let w = max(1, Int(CGFloat(img.width) * factor)), h = max(1, Int(CGFloat(img.height) * factor))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConversionError("Could not create the resized image.") }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw ConversionError("Could not create the resized image.") }
        return out
    }

    static func rotated90(_ img: CGImage) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: img.height, height: img.width, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConversionError("Could not create the edited image.") }
        // Clockwise: map (x, y) -> (y, w - x).
        ctx.translateBy(x: 0, y: CGFloat(img.width))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard let out = ctx.makeImage() else { throw ConversionError("Could not create the edited image.") }
        return out
    }

    /// Output type for in-place edits (resize, rotate, compress): keep the source format when ImageIO can write it.
    static func sameFormatType(_ src: URL) -> UTType {
        if let t = UTType(filenameExtension: src.pathExtension.lowercased()),
           OutputFormat.writableImageTypes.contains(t.identifier) { return t }
        return .png
    }
}

// MARK: - Audio & video

enum Media {
    static func export(_ asset: AVAsset, preset: String, to out: URL, type: AVFileType,
                       stripMetadata: Bool = false, timeRange: CMTimeRange? = nil) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError("No installed converter for this file.")
        }
        guard session.supportedFileTypes.contains(type) else {
            throw ConversionError("Conversion to .\(out.pathExtension) is unavailable for this file.")
        }
        session.outputURL = out
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        session.audioTimePitchAlgorithm = .spectral
        if let timeRange { session.timeRange = timeRange }
        if stripMetadata {
            session.metadata = []
            session.metadataItemFilter = .forSharing()
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { c.resume() }
        }
        if session.status != .completed {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError(session.error?.localizedDescription ?? "The conversion process failed.")
        }
    }

    static func exportVideo(_ src: URL, to fmt: OutputFormat) async throws -> URL {
        let asset = AVURLAsset(url: src)
        let out = Output.url(beside: src, ext: fmt.fileExtension)
        let type: AVFileType = switch fmt { case .mov: .mov; case .m4v: .m4v; default: .mp4 }
        // Passthrough keeps quality when the codecs fit the container; otherwise re-encode.
        var lastError: Error = ConversionError("The conversion process failed.")
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            do { try await export(asset, preset: preset, to: out, type: type); return out }
            catch { lastError = error }
        }
        throw lastError
    }

    static func extractAudio(_ src: URL) async throws -> URL {
        let asset = AVURLAsset(url: src)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw ConversionError("This file has no audio track.")
        }
        let out = Output.url(beside: src, ext: "m4a")
        try await export(asset, preset: AVAssetExportPresetAppleM4A, to: out, type: .m4a)
        return out
    }

    static func compressVideo(_ src: URL) async throws -> URL {
        let asset = AVURLAsset(url: src)
        let out = Output.url(beside: src, name: src.deletingPathExtension().lastPathComponent + " compressed", ext: "mp4")
        let preset = switch Settings.shared.videoCompression {
        case 0: AVAssetExportPresetHEVC1920x1080
        case 1: AVAssetExportPreset1280x720
        default: AVAssetExportPreset960x540
        }
        try await export(asset, preset: preset, to: out, type: .mp4)
        return out
    }

    static func stripVideoMetadata(_ src: URL) async throws -> URL {
        let asset = AVURLAsset(url: src)
        let ext = src.pathExtension.lowercased()
        let type: AVFileType = ext == "mov" ? .mov : ext == "m4v" ? .m4v : .mp4
        let out = Output.url(beside: src, name: src.deletingPathExtension().lastPathComponent + " clean",
                             ext: type == .mov ? "mov" : type == .m4v ? "m4v" : "mp4")
        try await export(asset, preset: AVAssetExportPresetPassthrough, to: out, type: type, stripMetadata: true)
        return out
    }

    /// Animated GIF at 12 fps and up to 480 px, capped at 15 seconds.
    static func gif(from src: URL) async throws -> URL {
        let asset = AVURLAsset(url: src)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ConversionError("This file has no playable duration.") }
        let fps = 12.0, length = min(duration, 15)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let out = Output.url(beside: src, ext: "gif")
        let count = max(1, Int(length * fps))
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw ConversionError("Could not create the GIF.")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            let img = try await gen.image(at: t).image
            CGImageDestinationAddImage(dest, img, frameProps)
        }
        guard CGImageDestinationFinalize(dest) else { throw ConversionError("Could not finish the GIF.") }
        return out
    }

    /// Audio conversions go through macOS's built-in `afconvert`.
    static func convertAudio(_ src: URL, to fmt: OutputFormat) throws -> URL {
        let out = Output.url(beside: src, ext: fmt.fileExtension)
        let args: [String] = switch fmt {
        case .m4a: ["-f", "m4af", "-d", "aac", "-s", "3", "-q", "127"]   // VBR, highest quality
        case .alac: ["-f", "m4af", "-d", "alac"]
        case .wav: ["-f", "WAVE", "-d", "LEI16"]
        case .aiff: ["-f", "AIFF", "-d", "BEI16"]
        case .flac: ["-f", "flac", "-d", "flac"]
        case .caf: ["-f", "caff", "-d", "LEI16"]
        default: throw ConversionError("Conversion to \(fmt.label) is unavailable.")
        }
        do { try Output.run("/usr/bin/afconvert", args + [src.path, out.path]) }
        catch { try? FileManager.default.removeItem(at: out); throw error }
        return out
    }
}

// MARK: - PDF

enum PDFs {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else {
            throw ConversionError("The PDF cannot be read, is empty, or is password-protected.")
        }
        return doc
    }

    static func convert(_ src: URL, to fmt: OutputFormat) throws -> [URL] {
        let doc = try open(src)
        switch fmt {
        case .pdfToText:
            let out = Output.url(beside: src, ext: "txt")
            guard let text = doc.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConversionError("This PDF has no selectable text. Scanned pages need OCR before text can be exported.")
            }
            try text.write(to: out, atomically: true, encoding: .utf8)
            return [out]
        case .pdfToRTF:
            let out = Output.url(beside: src, ext: "rtf")
            let attr = NSMutableAttributedString()
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.attributedString {
                    if attr.length > 0 { attr.append(NSAttributedString(string: "\n\n")) }
                    attr.append(page)
                }
            }
            guard attr.length > 0,
                  let data = attr.rtf(from: NSRange(location: 0, length: attr.length), documentAttributes: [:])
            else { throw ConversionError("This PDF has no selectable text.") }
            try data.write(to: out)
            return [out]
        case .pdfToPNG, .pdfToJPEG:
            return try renderPages(doc, src: src, type: fmt == .pdfToPNG ? .png : .jpeg, ext: fmt.fileExtension)
        default:
            throw ConversionError("Conversion from PDF to \(fmt.label) is unavailable.")
        }
    }

    static func pageImage(_ page: PDFPage, scale: CGFloat = 2) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    static func renderPages(_ doc: PDFDocument, src: URL, type: UTType, ext: String) throws -> [URL] {
        let base = src.deletingPathExtension().lastPathComponent
        if doc.pageCount == 1, let page = doc.page(at: 0), let img = pageImage(page) {
            let out = Output.url(beside: src, ext: ext)
            try Images.write([img], to: out, type: type, quality: Settings.shared.imageQuality)
            return [out]
        }
        let folder = Output.folder(beside: src, name: base)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let img = pageImage(page) else {
                throw ConversionError("Could not create the PDF page image.")
            }
            let num = String(i + 1).leftPadded(to: digits)
            try Images.write([img], to: folder.appendingPathComponent("\(base) \(num).\(ext)"), type: type,
                             quality: Settings.shared.imageQuality)
        }
        return [folder]
    }

    static func merge(_ sources: [URL]) throws -> URL {
        let merged = PDFDocument()
        for src in sources {
            let doc = try open(src)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        let out = Output.url(beside: sources[0], name: "Merged", ext: "pdf")
        guard merged.write(to: out) else { throw ConversionError("PDFKit could not write the combined PDF.") }
        return out
    }

    static func compress(_ src: URL) throws -> URL {
        let doc = try open(src)
        let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
        guard let filter = QuartzFilter(url: filterURL) else {
            throw ConversionError("The macOS PDF compression filter is unavailable.")
        }
        let out = Output.url(beside: src, name: src.deletingPathExtension().lastPathComponent + " compressed", ext: "pdf")
        guard doc.write(to: out, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) else {
            throw ConversionError("Could not create the compressed PDF.")
        }
        return out
    }

    static func stripMetadata(_ src: URL) throws -> URL {
        let doc = try open(src)
        doc.documentAttributes = [:]
        let out = Output.url(beside: src, name: src.deletingPathExtension().lastPathComponent + " clean", ext: "pdf")
        guard doc.write(to: out) else { throw ConversionError("PDFKit could not write the cleaned PDF.") }
        return out
    }
}

// MARK: - Documents

enum Documents {
    static func load(_ src: URL) throws -> NSAttributedString {
        let ext = src.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" {
            let text = try String(contentsOf: src, encoding: .utf8)
            let parsed = try AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return NSAttributedString(parsed)
        }
        if ext == "txt" || UTType(filenameExtension: ext)?.conforms(to: .plainText) == true {
            let text = try String(contentsOf: src)
            return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        return try NSAttributedString(url: src, options: [:], documentAttributes: nil)
    }

    static func convert(_ src: URL, to fmt: OutputFormat) async throws -> URL {
        let out = Output.url(beside: src, ext: fmt.fileExtension)
        let ext = src.pathExtension.lowercased()
        let textutilInputs: Set<String> = ["txt", "rtf", "rtfd", "html", "htm", "doc", "docx", "odt", "wordml", "webarchive"]
        let textutilOutputs: [OutputFormat: String] = [.docx: "docx", .rtf: "rtf", .txt: "txt", .html: "html", .odt: "odt"]

        if let target = textutilOutputs[fmt], textutilInputs.contains(ext) {
            try Output.run("/usr/bin/textutil", ["-convert", target, src.path, "-output", out.path])
            return out
        }
        let attr = try load(src)
        switch fmt {
        case .docPDF:
            try await MainActor.run { try renderPDF(attr, to: out) }
        case .markdown:
            try markdown(from: attr).write(to: out, atomically: true, encoding: .utf8)
        case .txt:
            try attr.string.write(to: out, atomically: true, encoding: .utf8)
        default:
            let docType: NSAttributedString.DocumentType = switch fmt {
            case .docx: .officeOpenXML; case .html: .html; case .odt: .openDocument; default: .rtf
            }
            let data = try attr.data(from: NSRange(location: 0, length: attr.length),
                                     documentAttributes: [.documentType: docType])
            try data.write(to: out)
        }
        return out
    }

    /// Paginates rich text onto US Letter pages with 1-inch margins.
    @MainActor
    static func renderPDF(_ attr: NSAttributedString, to out: URL) throws {
        let pageSize = NSSize(width: 612, height: 792), margin: CGFloat = 72
        let info = NSPrintInfo()
        info.paperSize = pageSize
        info.topMargin = margin; info.bottomMargin = margin; info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: pageSize.width - 2 * margin, height: pageSize.height))
        view.textStorage?.setAttributedString(attr)
        view.isVerticallyResizable = true
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: out.path) else {
            throw ConversionError("Document to PDF failed: The document could not be printed as PDF.")
        }
    }

    /// Lightweight rich text -> Markdown: bold, italic, links and paragraphs.
    static func markdown(from attr: NSAttributedString) -> String {
        var result = ""
        attr.enumerateAttributes(in: NSRange(location: 0, length: attr.length)) { attrs, range, _ in
            var text = (attr.string as NSString).substring(with: range)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { result += text; return }
            let traits = (attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let lead = String(text.prefix { $0.isWhitespace })
            let trail = String(text.reversed().prefix { $0.isWhitespace }.reversed())
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if traits.contains(.bold) { text = "**\(text)**" }
            if traits.contains(.italic) { text = "*\(text)*" }
            if let link = attrs[.link] { text = "[\(text)](\(link))" }
            result += lead + text + trail
        }
        return result.replacingOccurrences(of: "\n", with: "\n\n")
    }
}

// MARK: - Subtitles

enum Subtitles {
    static func convert(_ src: URL, to fmt: OutputFormat) throws -> URL {
        var text = try String(contentsOf: src).replacingOccurrences(of: "\r\n", with: "\n")
        let out = Output.url(beside: src, ext: fmt.fileExtension)
        let stamp = try NSRegularExpression(pattern: #"(\d{2}:\d{2}:\d{2})[.,](\d{3})"#)
        let separator = fmt == .vtt ? "." : ","
        text = stamp.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: "$1\(separator)$2")
        var blocks = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
        if blocks.first?.hasPrefix("WEBVTT") == true { blocks.removeFirst() }
        let cues = blocks.filter { $0.contains("-->") }
        guard !cues.isEmpty else { throw ConversionError("No valid subtitle cues were found.") }
        let body: String
        if fmt == .vtt {
            body = "WEBVTT\n\n" + cues.joined(separator: "\n\n") + "\n"
        } else {
            body = cues.enumerated().map { i, cue in
                var lines = cue.components(separatedBy: "\n")
                if !lines[0].contains("-->") { lines.removeFirst() }   // drop existing cue id
                return "\(i + 1)\n" + lines.joined(separator: "\n")
            }.joined(separator: "\n\n") + "\n"
        }
        try body.write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
