import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Broad family a dropped file belongs to; drives which wheel petals are offered.
enum FileKind: String {
    case image, video, audio, pdf, document, subtitle, archive, folder, other

    static func of(_ url: URL) -> FileKind {
        if url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if url.pathExtension.lowercased() == "rtfd" { return .document }
            return .folder
        }
        let ext = url.pathExtension.lowercased()
        if ["srt", "vtt"].contains(ext) { return .subtitle }
        if ["md", "markdown"].contains(ext) { return .document }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .zip) || type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .text) || type.conforms(to: .rtf) || type.conforms(to: .html)
            || ["doc", "docx", "odt", "rtfd", "webarchive", "wordml"].contains(ext) { return .document }
        return .other
    }
}

/// Output formats Limevert can write.
enum OutputFormat: String, CaseIterable {
    // images
    case png, jpeg, heic, avif, tiff, gif, bmp, webp, icns, imagePDF
    // video
    case mp4, mov, m4v, animatedGIF
    // audio
    case m4a, wav, aiff, flac, caf, alac
    // documents
    case docx, rtf, txt, html, odt, docPDF, markdown
    // pdf
    case pdfToPNG, pdfToJPEG, pdfToText, pdfToRTF
    // subtitles
    case srt, vtt

    var label: String {
        switch self {
        case .png: "PNG"; case .jpeg: "JPEG"; case .heic: "HEIC"; case .avif: "AVIF"; case .tiff: "TIFF"
        case .gif, .animatedGIF: "GIF"; case .bmp: "BMP"; case .webp: "WebP"; case .icns: "ICNS"
        case .imagePDF, .docPDF: "PDF"
        case .mp4: "MP4"; case .mov: "MOV"; case .m4v: "M4V"
        case .m4a: "M4A"; case .wav: "WAV"; case .aiff: "AIFF"; case .flac: "FLAC"; case .caf: "CAF"; case .alac: "ALAC"
        case .docx: "DOCX"; case .rtf: "RTF"; case .txt: "TXT"; case .html: "HTML"; case .odt: "ODT"; case .markdown: "MD"
        case .pdfToPNG: "PNG"; case .pdfToJPEG: "JPEG"; case .pdfToText: "TXT"; case .pdfToRTF: "RTF"
        case .srt: "SRT"; case .vtt: "VTT"
        }
    }

    var fileExtension: String {
        switch self {
        case .png, .pdfToPNG: "png"; case .jpeg, .pdfToJPEG: "jpg"; case .heic: "heic"; case .avif: "avif"; case .tiff: "tiff"
        case .gif, .animatedGIF: "gif"; case .bmp: "bmp"; case .webp: "webp"; case .icns: "icns"
        case .imagePDF, .docPDF: "pdf"
        case .mp4: "mp4"; case .mov: "mov"; case .m4v: "m4v"
        case .m4a, .alac: "m4a"; case .wav: "wav"; case .aiff: "aiff"; case .flac: "flac"; case .caf: "caf"
        case .docx: "docx"; case .rtf, .pdfToRTF: "rtf"; case .txt, .pdfToText: "txt"; case .html: "html"; case .odt: "odt"
        case .markdown: "md"
        case .srt: "srt"; case .vtt: "vtt"
        }
    }

    /// ImageIO type identifier for still-image outputs.
    var imageType: UTType? {
        switch self {
        case .png: .png; case .jpeg: .jpeg; case .heic: .heic; case .avif: UTType("public.avif"); case .tiff: .tiff
        case .gif: .gif; case .bmp: .bmp; case .webp: .webP; case .icns: .icns
        default: nil
        }
    }

    static let writableImageTypes: Set<String> =
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    var isAvailable: Bool {
        if let t = imageType { return Self.writableImageTypes.contains(t.identifier) }
        return true
    }
}

/// Everything a wheel petal can do.
enum WheelAction: Hashable {
    case convert(OutputFormat)
    case tool(FileToolKind)

    var label: String {
        switch self {
        case .convert(let f): f.label
        case .tool(let t): t.label
        }
    }

    var symbol: String? {
        switch self {
        case .convert: nil
        case .tool(let t): t.symbol
        }
    }
}

enum FileToolKind: String, CaseIterable {
    case compress, removeMetadata, resize, rotate, flip, removeBackground, readQR, combinePDF, mergePDF, splitPDF
    case extractAudio, mute, joinVideos, normalize, mono, stereo
    // editors
    case crop, adjust, annotate, redact, frame, collage
    case trimVideo, splitVideo, speed, snapshot
    case trimAudio, bleep, visualize
    case organizePDF
    // shared
    case zip, unzip, float, copyPaths, copyFiles, airDrop, terminal, moveTo

    var label: String {
        switch self {
        case .compress: "Compress"
        case .removeMetadata: "Strip Metadata"
        case .resize: "Resize 50%"
        case .rotate: "Rotate"
        case .flip: "Flip"
        case .removeBackground: "Remove BG"
        case .readQR: "Read QR"
        case .combinePDF: "Combine PDF"
        case .mergePDF: "Merge PDFs"
        case .splitPDF: "Split Pages"
        case .extractAudio: "Extract Audio"
        case .mute: "Mute"
        case .joinVideos: "Join"
        case .normalize: "Normalize"
        case .mono: "Mono"
        case .stereo: "Stereo"
        case .crop: "Crop"
        case .adjust: "Adjust"
        case .annotate: "Annotate"
        case .redact: "Redact"
        case .frame: "Frame"
        case .collage: "Collage"
        case .trimVideo, .trimAudio: "Trim"
        case .splitVideo: "Split"
        case .speed: "Speed"
        case .snapshot: "Snapshot"
        case .bleep: "Bleep"
        case .visualize: "Visualizer"
        case .organizePDF: "Organize"
        case .zip: "Zip"
        case .unzip: "Unzip"
        case .float: "Float"
        case .copyPaths: "Copy Paths"
        case .copyFiles: "Copy"
        case .airDrop: "AirDrop"
        case .terminal: "Terminal"
        case .moveTo: "Move To…"
        }
    }

    var symbol: String {
        switch self {
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .removeMetadata: "eye.slash"
        case .resize: "arrow.up.left.and.down.right.magnifyingglass"
        case .rotate: "rotate.right"
        case .flip: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .removeBackground: "wand.and.stars"
        case .readQR: "qrcode.viewfinder"
        case .combinePDF, .mergePDF: "doc.on.doc"
        case .splitPDF: "square.split.1x2"
        case .extractAudio: "waveform"
        case .mute: "speaker.slash"
        case .joinVideos: "film.stack"
        case .normalize: "speaker.wave.3"
        case .mono: "speaker"
        case .stereo: "hifispeaker.2"
        case .crop: "crop"
        case .adjust: "slider.horizontal.3"
        case .annotate: "pencil.tip.crop.circle"
        case .redact: "rectangle.inset.filled"
        case .frame: "photo.artframe"
        case .collage: "square.grid.2x2"
        case .trimVideo, .trimAudio: "scissors"
        case .splitVideo: "square.split.2x1"
        case .speed: "gauge.with.dots.needle.67percent"
        case .snapshot: "camera"
        case .bleep: "exclamationmark.bubble"
        case .visualize: "waveform.path"
        case .organizePDF: "square.grid.3x3"
        case .zip: "doc.zipper"
        case .unzip: "archivebox"
        case .float: "rectangle.stack"
        case .copyPaths: "link"
        case .copyFiles: "doc.on.clipboard"
        case .airDrop: "airplayaudio"
        case .terminal: "terminal"
        case .moveTo: "folder"
        }
    }

    /// Tools that open an editor window instead of running straight away.
    var opensEditor: Bool {
        switch self {
        case .crop, .adjust, .annotate, .redact, .frame, .collage, .trimVideo, .splitVideo, .speed, .snapshot,
             .trimAudio, .bleep, .visualize, .organizePDF: true
        default: false
        }
    }
}

enum ActionCatalog {
    /// Petals offered for a set of dragged files. Conversions first, then tools, then shared file actions.
    static func actions(for urls: [URL]) -> [WheelAction] {
        let kinds = Set(urls.map(FileKind.of))
        let single = urls.count == 1
        var conversions: [OutputFormat] = []
        var tools: [FileToolKind] = []

        if kinds.count == 1, let kind = kinds.first {
            switch kind {
            case .image:
                conversions = [.png, .jpeg, .heic, .avif, .webp, .tiff, .gif, .bmp, .icns, .imagePDF]
                tools = [.compress, .removeMetadata, .resize, .rotate, .flip, .removeBackground, .readQR]
                tools += single ? [.crop, .adjust, .annotate, .redact, .frame] : [.combinePDF, .collage]
            case .video:
                conversions = [.mp4, .mov, .m4v, .animatedGIF]
                tools = [.compress, .removeMetadata, .extractAudio, .mute]
                tools += single ? [.trimVideo, .splitVideo, .speed, .snapshot] : [.joinVideos]
            case .audio:
                conversions = [.m4a, .wav, .aiff, .flac, .alac, .caf]
                tools = [.normalize, .mono, .stereo]
                if single { tools += [.trimAudio, .bleep, .visualize] }
            case .pdf:
                conversions = [.pdfToPNG, .pdfToJPEG, .pdfToText, .pdfToRTF]
                tools = [.compress, .removeMetadata, .readQR, .splitPDF]
                tools += single ? [.organizePDF] : [.mergePDF]
            case .document:
                conversions = [.docx, .docPDF, .rtf, .txt, .html, .odt, .markdown]
            case .subtitle:
                conversions = [.srt, .vtt]
            case .archive:
                tools = [.unzip]
            case .folder, .other:
                break
            }
        }
        // Drop formats that match every source already (e.g. PNG -> PNG).
        let sourceExts = Set(urls.map { $0.pathExtension.lowercased() })
        conversions = conversions.filter { fmt in
            fmt.isAvailable && !(sourceExts.count == 1 && sourceExts.contains(fmt.fileExtension)
                                  && ![.pdfToPNG, .pdfToJPEG].contains(fmt))
        }

        var shared: [FileToolKind] = [.float, .zip, .copyPaths, .airDrop, .moveTo]
        if kinds == [.folder] { shared.insert(.terminal, at: 1) }
        // Editors last, so the wheel can give them their own ring.
        let quick = tools.filter { !$0.opensEditor }, editors = tools.filter(\.opensEditor)
        return conversions.map { .convert($0) } + (quick + shared + editors).map { .tool($0) }
    }
}
