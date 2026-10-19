import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Image processing behind the editors. Rects and points are normalized: 0...1, origin top-left,
/// so the same values drive the on-screen preview and the full-resolution render.
enum ImageEdits {
    static let context = CIContext()

    /// Writes an edit beside its source, keeping the format when possible.
    static func save(_ img: CGImage, beside src: URL, suffix: String, type forced: UTType? = nil) throws -> URL {
        let type = forced ?? Images.sameFormatType(src)
        let out = Output.url(beside: src, name: "\(src.deletingPathExtension().lastPathComponent) \(suffix)",
                             ext: type.preferredFilenameExtension ?? "png")
        let flat = [UTType.jpeg, .bmp].contains(type) ? Images.flattened(img) : img
        try Images.write([flat], to: out, type: type, quality: 0.92)
        return out
    }

    /// Pixel rect (top-left origin, as CGImage.cropping expects) for a normalized rect.
    static func pixelRect(_ r: CGRect, width: Int, height: Int) -> CGRect {
        CGRect(x: r.minX * CGFloat(width), y: r.minY * CGFloat(height),
               width: r.width * CGFloat(width), height: r.height * CGFloat(height)).integral
    }

    static func render(_ ci: CIImage, extent: CGRect) throws -> CGImage {
        guard let out = context.createCGImage(ci, from: extent) else { throw ConversionError("Could not render the image.") }
        return out
    }

    /// Bitmap context with a top-left origin, sized like the image.
    static func canvas(width: Int, height: Int) throws -> CGContext {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError("Could not allocate the image.")
        }
        return ctx
    }

    // MARK: Crop, flip

    static func crop(_ img: CGImage, to r: CGRect) throws -> CGImage {
        let rect = pixelRect(r, width: img.width, height: img.height)
        guard rect.width >= 2, rect.height >= 2, let out = img.cropping(to: rect) else {
            throw ConversionError("Make the crop at least 2 pixels wide and tall.")
        }
        return out
    }

    static func flipped(_ img: CGImage, horizontally: Bool = true) throws -> CGImage {
        let ctx = try canvas(width: img.width, height: img.height)
        if horizontally {
            ctx.translateBy(x: CGFloat(img.width), y: 0)
            ctx.scaleBy(x: -1, y: 1)
        } else {
            ctx.translateBy(x: 0, y: CGFloat(img.height))
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard let out = ctx.makeImage() else { throw ConversionError("Could not flip the image.") }
        return out
    }

    // MARK: Adjust

    struct Adjustments: Equatable {
        var exposure = 0.0      // EV, -2...2
        var contrast = 1.0      // 0.5...1.5
        var saturation = 1.0    // 0...2
        var highlights = 1.0    // 0...1, lower recovers highlights
        var shadows = 0.0       // -1...1, higher lifts shadows
        var warmth = 0.0        // -1...1
        var sharpness = 0.0     // 0...2
        var isIdentity: Bool { self == Adjustments() }
    }

    static func adjust(_ img: CGImage, _ a: Adjustments) throws -> CGImage {
        let source = CIImage(cgImage: img)
        var ci = source
        if a.exposure != 0 {
            let f = CIFilter.exposureAdjust(); f.inputImage = ci; f.ev = Float(a.exposure); ci = f.outputImage ?? ci
        }
        if a.contrast != 1 || a.saturation != 1 {
            let f = CIFilter.colorControls(); f.inputImage = ci
            f.contrast = Float(a.contrast); f.saturation = Float(a.saturation); f.brightness = 0
            ci = f.outputImage ?? ci
        }
        if a.highlights != 1 || a.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust(); f.inputImage = ci
            f.highlightAmount = Float(a.highlights); f.shadowAmount = Float(a.shadows)
            ci = f.outputImage ?? ci
        }
        if a.warmth != 0 {
            // A lower target neutral than the source neutral shifts colors warmer.
            let f = CIFilter.temperatureAndTint(); f.inputImage = ci
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 - a.warmth * 2500, y: 0)
            ci = f.outputImage ?? ci
        }
        if a.sharpness > 0 {
            let f = CIFilter.sharpenLuminance(); f.inputImage = ci; f.sharpness = Float(a.sharpness); ci = f.outputImage ?? ci
        }
        return try render(ci, extent: source.extent)
    }

    // MARK: Annotate

    struct RGBA: Equatable {
        var r, g, b, a: CGFloat
        var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
        static let palette: [RGBA] = [
            RGBA(r: 1, g: 0.23, b: 0.19, a: 1), RGBA(r: 1, g: 0.62, b: 0.04, a: 1), RGBA(r: 1, g: 0.84, b: 0.04, a: 1),
            RGBA(r: 0.55, g: 0.82, b: 0.2, a: 1), RGBA(r: 0.04, g: 0.52, b: 1, a: 1), RGBA(r: 0.69, g: 0.32, b: 0.87, a: 1),
            RGBA(r: 0, g: 0, b: 0, a: 1), RGBA(r: 1, g: 1, b: 1, a: 1),
        ]
    }

    enum MarkKind: String, CaseIterable, Identifiable {
        case pen, highlighter, arrow, rectangle, ellipse, text
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .pen: "scribble"
            case .highlighter: "highlighter"
            case .arrow: "arrow.up.right"
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            case .text: "textformat"
            }
        }
    }

    struct Mark: Identifiable {
        let id = UUID()
        var kind: MarkKind
        var points: [CGPoint]
        var color: RGBA
        /// Stroke width as a fraction of the image's shorter side.
        var width: CGFloat
        var text = ""
    }

    /// Draws marks into a context whose origin is top-left and whose size is `size`.
    static func draw(_ marks: [Mark], in ctx: CGContext, size: CGSize) {
        let unit = min(size.width, size.height)
        func p(_ n: CGPoint) -> CGPoint { CGPoint(x: n.x * size.width, y: n.y * size.height) }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for m in marks {
            guard let first = m.points.first else { continue }
            let w = max(1, m.width * unit)
            var color = m.color
            if m.kind == .highlighter { color.a = 0.38 }
            ctx.setStrokeColor(color.cgColor)
            ctx.setFillColor(color.cgColor)
            switch m.kind {
            case .pen, .highlighter:
                ctx.setLineWidth(m.kind == .highlighter ? w * 4 : w)
                ctx.beginPath()
                ctx.move(to: p(first))
                for pt in m.points.dropFirst() { ctx.addLine(to: p(pt)) }
                if m.points.count == 1 { ctx.addLine(to: p(first)) }
                ctx.strokePath()
            case .arrow:
                let a = p(first), b = p(m.points.last ?? first)
                let angle = atan2(b.y - a.y, b.x - a.x), head = w * 4.5
                ctx.setLineWidth(w)
                let shaftEnd = CGPoint(x: b.x - cos(angle) * head * 0.7, y: b.y - sin(angle) * head * 0.7)
                ctx.strokeLineSegments(between: [a, shaftEnd])
                ctx.beginPath()
                ctx.move(to: b)
                ctx.addLine(to: CGPoint(x: b.x - cos(angle - 0.45) * head, y: b.y - sin(angle - 0.45) * head))
                ctx.addLine(to: CGPoint(x: b.x - cos(angle + 0.45) * head, y: b.y - sin(angle + 0.45) * head))
                ctx.closePath()
                ctx.fillPath()
            case .rectangle, .ellipse:
                let a = p(first), b = p(m.points.last ?? first)
                let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                ctx.setLineWidth(w)
                if m.kind == .rectangle { ctx.stroke(r) } else { ctx.strokeEllipse(in: r) }
            case .text:
                guard !m.text.isEmpty else { continue }
                let font = NSFont.systemFont(ofSize: w * 9, weight: .bold)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: color.cgColor) ?? .red]
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                (m.text as NSString).draw(at: p(first), withAttributes: attrs)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        ctx.restoreGState()
    }

    static func annotate(_ img: CGImage, marks: [Mark]) throws -> CGImage {
        let ctx = try canvas(width: img.width, height: img.height)
        let size = CGSize(width: img.width, height: img.height)
        ctx.draw(img, in: CGRect(origin: .zero, size: size))
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(marks, in: ctx, size: size)
        guard let out = ctx.makeImage() else { throw ConversionError("Could not render the annotations.") }
        return out
    }

    // MARK: Redact

    enum RedactStyle: String, CaseIterable, Identifiable {
        case pixelate, blur, black
        var id: String { rawValue }
        var label: String { self == .black ? "Black Box" : rawValue.capitalized }
    }

    static func redact(_ img: CGImage, rects: [CGRect], style: RedactStyle) throws -> CGImage {
        let base = CIImage(cgImage: img)
        let extent = base.extent
        let side = max(extent.width, extent.height)
        let hidden: CIImage
        switch style {
        case .blur:
            hidden = base.clampedToExtent().applyingGaussianBlur(sigma: side * 0.025).cropped(to: extent)
        case .pixelate:
            let f = CIFilter.pixellate()
            f.inputImage = base.clampedToExtent()
            f.scale = Float(max(6, side / 60))
            f.center = .zero
            hidden = (f.outputImage ?? base).cropped(to: extent)
        case .black:
            hidden = CIImage(color: .black).cropped(to: extent)
        }
        var out = base
        for r in rects {
            // Core Image's origin is bottom-left.
            let pr = CGRect(x: r.minX * extent.width, y: (1 - r.maxY) * extent.height,
                            width: r.width * extent.width, height: r.height * extent.height)
            out = hidden.cropped(to: pr).composited(over: out)
        }
        return try render(out, extent: extent)
    }

    enum Detection { case faces, text }

    /// Normalized top-left rects of faces or text, padded slightly so edges are covered.
    static func detect(_ kind: Detection, in img: CGImage) throws -> [CGRect] {
        let handler = VNImageRequestHandler(cgImage: img)
        let boxes: [CGRect]
        switch kind {
        case .faces:
            let req = VNDetectFaceRectanglesRequest()
            try handler.perform([req])
            boxes = (req.results ?? []).map(\.boundingBox)
        case .text:
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .fast
            try handler.perform([req])
            boxes = (req.results ?? []).map(\.boundingBox)
        }
        return boxes.map { b in
            let pad = kind == .faces ? 0.12 : 0.04
            let r = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
                .insetBy(dx: -b.width * pad, dy: -b.height * pad * 2)
            return r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    // MARK: Background

    static func removeBackground(_ img: CGImage) throws -> CGImage {
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: img)
        try handler.perform([req])
        guard let result = req.results?.first, !result.allInstances.isEmpty else {
            throw ConversionError("No clear subject was found in this image.")
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                    croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        return try render(ci, extent: ci.extent)
    }

    // MARK: Frame

    struct FrameBackground: Identifiable, Equatable {
        let id: String
        let colors: [RGBA]   // one color = solid, two = diagonal gradient, none = transparent
        static let presets: [FrameBackground] = [
            .init(id: "Lime", colors: [RGBA(r: 0.80, g: 0.93, b: 0.42, a: 1), RGBA(r: 0.22, g: 0.55, b: 0.16, a: 1)]),
            .init(id: "Ocean", colors: [RGBA(r: 0.40, g: 0.80, b: 0.98, a: 1), RGBA(r: 0.17, g: 0.30, b: 0.85, a: 1)]),
            .init(id: "Sunset", colors: [RGBA(r: 1.0, g: 0.78, b: 0.36, a: 1), RGBA(r: 0.93, g: 0.27, b: 0.45, a: 1)]),
            .init(id: "Grape", colors: [RGBA(r: 0.85, g: 0.55, b: 1.0, a: 1), RGBA(r: 0.36, g: 0.20, b: 0.75, a: 1)]),
            .init(id: "Graphite", colors: [RGBA(r: 0.36, g: 0.38, b: 0.42, a: 1), RGBA(r: 0.10, g: 0.11, b: 0.13, a: 1)]),
            .init(id: "White", colors: [RGBA(r: 1, g: 1, b: 1, a: 1)]),
            .init(id: "Clear", colors: []),
        ]
    }

    enum CanvasRatio: String, CaseIterable, Identifiable {
        case auto = "Auto", square = "1:1", fourThree = "4:3", wide = "16:9", tall = "9:16"
        var id: String { rawValue }
        var value: CGFloat? {
            switch self { case .auto: nil; case .square: 1; case .fourThree: 4 / 3; case .wide: 16 / 9; case .tall: 9 / 16 }
        }
    }

    struct FrameOptions: Equatable {
        var padding = 0.08        // fraction of the longer side
        var cornerRadius = 0.03   // fraction of the shorter side
        var shadow = true
        var background = FrameBackground.presets[0]
        var ratio = CanvasRatio.auto
    }

    static func frame(_ img: CGImage, _ o: FrameOptions) throws -> CGImage {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let pad = o.padding * max(iw, ih)
        var cw = iw + 2 * pad, ch = ih + 2 * pad
        if let r = o.ratio.value {
            if cw / ch < r { cw = ch * r } else { ch = cw / r }
        }
        let ctx = try canvas(width: Int(cw.rounded()), height: Int(ch.rounded()))
        let full = CGRect(x: 0, y: 0, width: cw, height: ch)
        switch o.background.colors.count {
        case 0: break
        case 1: ctx.setFillColor(o.background.colors[0].cgColor); ctx.fill(full)
        default:
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: o.background.colors.map(\.cgColor) as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: ch), end: CGPoint(x: cw, y: 0), options: [])
        }
        let rect = CGRect(x: (cw - iw) / 2, y: (ch - ih) / 2, width: iw, height: ih)
        let radius = o.cornerRadius * min(iw, ih)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if o.shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -max(iw, ih) * 0.012), blur: max(iw, ih) * 0.04,
                          color: CGColor(gray: 0, alpha: 0.4))
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(img, in: rect)
        ctx.restoreGState()
        guard let out = ctx.makeImage() else { throw ConversionError("Could not render the frame.") }
        return out
    }

    // MARK: Collage

    struct CollageOptions: Equatable {
        var columns = 0           // 0 = automatic
        var spacing = 0.02        // fraction of the cell width
        var fill = true           // crop to fill each cell, or fit inside it
        var background = FrameBackground.presets[5]
        var cellWidth = 1200
    }

    static func collage(_ imgs: [CGImage], _ o: CollageOptions) throws -> CGImage {
        guard !imgs.isEmpty else { throw ConversionError("Add at least one image.") }
        let n = imgs.count
        let cols = o.columns > 0 ? min(o.columns, n) : Int(ceil(sqrt(Double(n))))
        let rows = Int(ceil(Double(n) / Double(cols)))
        let aspects = imgs.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) }.sorted()
        let aspect = aspects[aspects.count / 2]
        let cellW = CGFloat(o.cellWidth), cellH = (cellW / aspect).rounded()
        let gap = (o.spacing * cellW).rounded()
        let w = CGFloat(cols) * cellW + CGFloat(cols + 1) * gap
        let h = CGFloat(rows) * cellH + CGFloat(rows + 1) * gap
        let ctx = try canvas(width: Int(w), height: Int(h))
        if let c = o.background.colors.first { ctx.setFillColor(c.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        ctx.interpolationQuality = .high
        for (i, img) in imgs.enumerated() {
            let col = i % cols, row = i / cols
            // CG's origin is bottom-left; lay rows out from the top.
            let cell = CGRect(x: gap + CGFloat(col) * (cellW + gap), y: h - gap - CGFloat(row + 1) * cellH - CGFloat(row) * gap,
                              width: cellW, height: cellH)
            let iw = CGFloat(img.width), ih = CGFloat(img.height)
            let scale = o.fill ? max(cellW / iw, cellH / ih) : min(cellW / iw, cellH / ih)
            let dw = iw * scale, dh = ih * scale
            ctx.saveGState()
            ctx.clip(to: cell)
            ctx.draw(img, in: CGRect(x: cell.midX - dw / 2, y: cell.midY - dh / 2, width: dw, height: dh))
            ctx.restoreGState()
        }
        guard let out = ctx.makeImage() else { throw ConversionError("Could not create the collage.") }
        return out
    }
}

// MARK: - PDF pages

enum PDFEdits {
    /// One PDF per page, in a folder beside the source.
    static func split(_ src: URL) throws -> [URL] {
        let doc = try PDFs.open(src)
        guard doc.pageCount > 1 else { throw ConversionError("This PDF has only one page.") }
        let base = src.deletingPathExtension().lastPathComponent
        let folder = Output.folder(beside: src, name: "\(base) pages")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let n = String(i + 1).leftPadded(to: digits)
            guard single.write(to: folder.appendingPathComponent("\(base) page \(n).pdf")) else {
                throw ConversionError("Could not write page \(i + 1).")
            }
        }
        return [folder]
    }

    struct PageRef: Identifiable, Equatable {
        let id = UUID()
        let index: Int
        var rotation = 0
    }

    /// A new PDF with the pages in the given order and rotation; omitted pages are dropped.
    static func organize(_ src: URL, pages: [PageRef]) throws -> URL {
        guard !pages.isEmpty else { throw ConversionError("Keep at least one page.") }
        let doc = try PDFs.open(src)
        let out = PDFDocument()
        for ref in pages {
            guard let page = doc.page(at: ref.index)?.copy() as? PDFPage else { continue }
            page.rotation = (page.rotation + ref.rotation + 360) % 360
            out.insert(page, at: out.pageCount)
        }
        let url = Output.url(beside: src, name: "\(src.deletingPathExtension().lastPathComponent) organized", ext: "pdf")
        guard out.write(to: url) else { throw ConversionError("Could not create the organized PDF.") }
        return url
    }
}
