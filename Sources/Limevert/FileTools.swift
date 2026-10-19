import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Background tools that produce new files beside the originals.
enum FileTools {
    static func run(_ tool: FileToolKind, on urls: [URL]) async throws -> [URL] {
        switch tool {
        case .combinePDF:
            return [try Images.toPDF(urls, output: Output.url(beside: urls[0], name: "Combined", ext: "pdf"))]
        case .mergePDF:
            return [try PDFs.merge(urls)]
        case .zip:
            return [try zip(urls)]
        default:
            var outputs: [URL] = []
            for url in urls { outputs += try await runSingle(tool, on: url) }
            return outputs
        }
    }

    private static func runSingle(_ tool: FileToolKind, on url: URL) async throws -> [URL] {
        switch (tool, FileKind.of(url)) {
        case (.compress, .image): return [try compressImage(url)]
        case (.compress, .pdf): return [try PDFs.compress(url)]
        case (.compress, .video): return [try await Media.compressVideo(url)]
        case (.removeMetadata, .image): return [try stripImageMetadata(url)]
        case (.removeMetadata, .pdf): return [try PDFs.stripMetadata(url)]
        case (.removeMetadata, .video): return [try await Media.stripVideoMetadata(url)]
        case (.resize, .image): return [try edit(url, suffix: "resized") { try Images.scaled($0, by: 0.5) }]
        case (.rotate, .image): return [try edit(url, suffix: "rotated") { try Images.rotated90($0) }]
        case (.extractAudio, .video): return [try await Media.extractAudio(url)]
        case (.unzip, .archive): return [try unzip(url)]
        default: throw ConversionError("\(tool.label) is unavailable for this file type.")
        }
    }

    private static func edit(_ src: URL, suffix: String, _ transform: (CGImage) throws -> CGImage) throws -> URL {
        let type = Images.sameFormatType(src)
        let img = try transform(try Images.loadOriented(src))
        let out = Output.url(beside: src, name: "\(src.deletingPathExtension().lastPathComponent) \(suffix)",
                             ext: type.preferredFilenameExtension ?? "png")
        try Images.write([img], to: out, type: type, quality: 0.92)
        return out
    }

    /// Lossy formats are re-encoded at the compression quality; PNG and other
    /// lossless sources become HEIC unless the setting asks to keep the format.
    static func compressImage(_ src: URL) throws -> URL {
        var type = Images.sameFormatType(src)
        let lossy: Set<UTType> = [.jpeg, .heic, .webP]
        if !lossy.contains(type) && !Settings.shared.keepFormatWhenCompressing { type = .heic }
        let base = src.deletingPathExtension().lastPathComponent + " compressed"
        let out = Output.url(beside: src, name: base, ext: type.preferredFilenameExtension ?? "heic")
        var img = try Images.loadOriented(src)
        if let edge = Settings.shared.compressMaxEdge, max(img.width, img.height) > edge {
            img = try Images.scaled(img, by: CGFloat(edge) / CGFloat(max(img.width, img.height)))
        }
        if type == .jpeg { img = Images.flattened(img) }
        try Images.write([img], to: out, type: type, quality: Settings.shared.compressionQuality)
        let before = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        let after = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if after >= before {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError("Compressed output would exceed the original file size.")
        }
        return out
    }

    /// Re-encodes pixels only, with orientation applied, so EXIF, GPS, XMP and maker notes are dropped.
    static func stripImageMetadata(_ src: URL) throws -> URL {
        let type = Images.sameFormatType(src)
        let img = try Images.loadOriented(src)
        let out = Output.url(beside: src, name: src.deletingPathExtension().lastPathComponent + " clean",
                             ext: type.preferredFilenameExtension ?? "png")
        try Images.write([img], to: out, type: type, quality: 0.95)
        return out
    }

    static func zip(_ urls: [URL]) throws -> URL {
        if urls.count == 1 {
            let out = Output.url(beside: urls[0], name: urls[0].lastPathComponent, ext: "zip")
            try Output.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, out.path])
            return out
        }
        // Several items: stage them in a temporary folder so the archive has a flat top level.
        let out = Output.url(beside: urls[0], name: "Archive", ext: "zip")
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        for url in urls { try FileManager.default.copyItem(at: url, to: stage.appendingPathComponent(url.lastPathComponent)) }
        try Output.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", stage.path, out.path])
        return out
    }

    static func unzip(_ src: URL) throws -> URL {
        guard src.pathExtension.lowercased() == "zip" else {
            throw ConversionError("Only ZIP archives can be extracted.")
        }
        let folder = Output.folder(beside: src, name: src.deletingPathExtension().lastPathComponent)
        try Output.run("/usr/bin/ditto", ["-x", "-k", src.path, folder.path])
        return folder
    }

    // MARK: QR codes

    static func readQRCodes(_ urls: [URL]) throws -> [(file: String, payload: String)] {
        var results: [(String, String)] = []
        for url in urls {
            var images: [CGImage] = []
            if FileKind.of(url) == .pdf {
                let doc = try PDFs.open(url)
                for i in 0..<doc.pageCount { if let p = doc.page(at: i), let img = PDFs.pageImage(p) { images.append(img) } }
            } else {
                images.append(try Images.loadOriented(url))
            }
            for img in images {
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.qr, .microQR, .aztec, .dataMatrix, .pdf417]
                try VNImageRequestHandler(cgImage: img).perform([request])
                for obs in request.results ?? [] {
                    if let s = obs.payloadStringValue { results.append((url.lastPathComponent, s)) }
                }
            }
        }
        return results
    }
}

/// Tools that act immediately on the dragged files without creating new ones.
@MainActor
enum InstantActions {
    static func copyPaths(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        HUD.shared.flash("Copied \(urls.count == 1 ? "path" : "\(urls.count) paths")")
    }

    static func copyFiles(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        HUD.shared.flash("Copied \(urls.count) item\(urls.count == 1 ? "" : "s")")
    }

    static func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            HUD.shared.flash("AirDrop isn’t available for these files on this Mac.", isError: true)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    static func openTerminal(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let folder = FileKind.of(first) == .folder ? first : first.deletingLastPathComponent()
        let appName = Settings.shared.terminalApp
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalApp.bundleID(for: appName)) else {
            HUD.shared.flash("\(appName) isn’t installed.", isError: true)
            return
        }
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            let message = "Couldn’t open terminal: \(error.localizedDescription)"
            DispatchQueue.main.async { HUD.shared.flash(message, isError: true) }
        }
    }

    static func moveTo(_ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move"
        panel.message = "Choose a destination folder for \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        var moved: [URL] = []
        for url in urls {
            // Never move a folder into itself.
            if dest == url || dest.path.hasPrefix(url.path + "/") { continue }
            let target = dest.appendingPathComponent(url.lastPathComponent)
            if (try? FileManager.default.moveItem(at: url, to: target)) != nil { moved.append(target) }
        }
        if moved.isEmpty { HUD.shared.flash("No items were moved.", isError: true) }
        else { NSWorkspace.shared.activateFileViewerSelecting(moved) }
    }
}

enum TerminalApp {
    static let choices = ["Terminal", "iTerm", "Ghostty", "Warp", "WezTerm"]
    static func bundleID(for name: String) -> String {
        switch name {
        case "iTerm": "com.googlecode.iterm2"
        case "Ghostty": "com.mitchellh.ghostty"
        case "Warp": "dev.warp.Warp-Stable"
        case "WezTerm": "com.github.wez.wezterm"
        default: "com.apple.Terminal"
        }
    }
}
