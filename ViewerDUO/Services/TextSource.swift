import Foundation
import UIKit
import CoreText
import ImageIO

/// Reflowable text (TXT / EPUB) laid out with CoreText into fixed pages.
final class TextSource: PageSource {
    private struct PageRef {
        let chapter: Int
        let range: CFRange
    }

    private let chapterTexts: [ChapterText]
    private let chapterOffsets: [Int]          // global character offset where each chapter starts
    private let bookTitle: String
    private var styled: [NSAttributedString] = []
    private var framesetters: [CTFramesetter] = []
    private var pages: [PageRef] = []
    private var chapterStartPage: [Int] = []
    private var laidOutSize: CGSize = .zero
    private var laidOutStyle: TextStyle?
    private var imageCache: [URL: CGImage] = [:]
    private let lock = NSRecursiveLock()
    private(set) var chapters: [Chapter] = []

    let aspect: CGFloat = 1.45
    var isReflowable: Bool { true }
    var supportsSearch: Bool { true }
    var pageCount: Int { max(1, pages.count) }
    var totalCharacters: Int { chapterOffsets.last ?? 0 }

    init(chapters: [ChapterText], title: String) {
        chapterTexts = chapters.isEmpty ? [ChapterText(title: title, rich: NSAttributedString(string: " "))] : chapters
        bookTitle = title
        var offs: [Int] = [0]
        for c in chapterTexts { offs.append(offs.last! + c.rich.length) }
        chapterOffsets = offs
    }

    convenience init(plainTextURL url: URL, title: String) {
        let data = (try? Data(contentsOf: url)) ?? Data()
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .shiftJIS)
            ?? String(data: data, encoding: .japaneseEUC)
            ?? String(decoding: data, as: UTF8.self)
        self.init(chapters: RichText.fromPlainText(text, fallbackTitle: title), title: title)
    }

    convenience init(epub pkg: EPUBPackage, title: String) {
        var list: [ChapterText] = []
        for (i, u) in pkg.spine.enumerated() {
            let t = i < pkg.chapterTitles.count ? pkg.chapterTitles[i] : String(format: L10n.chapterN, i + 1)
            let ch = RichText.fromXHTML(url: u, title: t)
            if ch.rich.length > 0 { list.append(ch) }
        }
        self.init(chapters: list, title: title)
    }

    // MARK: - Offsets

    func offset(forPage page: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard !pages.isEmpty else { return 0 }
        let p = pages[min(max(0, page), pages.count - 1)]
        return chapterOffsets[p.chapter] + p.range.location
    }

    func page(forOffset offset: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard !pages.isEmpty else { return 0 }
        var lo = 0, hi = pages.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if self.offset(forPage: mid) <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    // MARK: - Layout

    private struct Metrics {
        let textRect: CGRect      // in points, top-left origin
        let footerY: CGFloat
        let headerY: CGFloat
    }

    private func metrics(for size: CGSize, style: TextStyle) -> Metrics {
        let m = style.margin
        let side = max(14, size.width * 0.075 * m)
        let top = max(22, size.height * 0.075 * m)
        let bottom = max(26, size.height * 0.085 * m)
        let rect = CGRect(x: side, y: top, width: max(20, size.width - side * 2), height: max(20, size.height - top - bottom))
        return Metrics(textRect: rect, footerY: size.height - bottom * 0.5, headerY: top * 0.45)
    }

    func prepare(pageSize: CGSize, style: TextStyle) {
        guard pageSize.width > 40, pageSize.height > 40 else { return }
        if laidOutSize == pageSize, let s = laidOutStyle, s == style { return }
        laidOutSize = pageSize
        laidOutStyle = style
        let met = metrics(for: pageSize, style: style)
        styled = chapterTexts.map { Self.applyStyle($0.rich, style: style, textRect: met.textRect) }
        framesetters = styled.map { CTFramesetterCreateWithAttributedString($0 as CFAttributedString) }
        var refs: [PageRef] = []
        var starts: [Int] = []
        let path = CGPath(rect: CGRect(origin: .zero, size: met.textRect.size), transform: nil)
        let frameAttrs = Self.frameAttributes(vertical: style.vertical)
        for (ci, fs) in framesetters.enumerated() {
            starts.append(refs.count)
            let len = styled[ci].length
            var start = 0
            var guardCount = 0
            while start < len && guardCount < 20_000 {
                guardCount += 1
                let frame = CTFramesetterCreateFrame(fs, CFRange(location: start, length: 0), path, frameAttrs)
                let visible = CTFrameGetVisibleStringRange(frame)
                if visible.length <= 0 {
                    // Nothing fits (e.g. an oversized image); skip a character rather than loop forever.
                    refs.append(PageRef(chapter: ci, range: CFRange(location: start, length: 1)))
                    start += 1
                    continue
                }
                refs.append(PageRef(chapter: ci, range: visible))
                start += visible.length
            }
            if len == 0 { refs.append(PageRef(chapter: ci, range: CFRange(location: 0, length: 0))) }
        }
        lock.lock()
        pages = refs
        chapterStartPage = starts
        lock.unlock()
        chapters = chapterTexts.enumerated().compactMap { i, c in
            chapterTexts.count > 1 ? Chapter(title: c.title, page: starts[i]) : nil
        }
    }

    private static func frameAttributes(vertical: Bool) -> CFDictionary? {
        guard vertical else { return nil }
        let d: [CFString: Any] = [kCTFrameProgressionAttributeName: NSNumber(value: CTFrameProgression.rightToLeft.rawValue)]
        return d as CFDictionary
    }

    // MARK: - Styling

    private final class ImageBox {
        let ascent: CGFloat
        let descent: CGFloat
        let width: CGFloat
        init(ascent: CGFloat, descent: CGFloat, width: CGFloat) {
            self.ascent = ascent
            self.descent = descent
            self.width = width
        }
    }

    private static func runDelegate(ascent: CGFloat, descent: CGFloat, width: CGFloat) -> CTRunDelegate? {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateCurrentVersion,
            dealloc: { ptr in Unmanaged<ImageBox>.fromOpaque(ptr).release() },
            getAscent: { ptr in Unmanaged<ImageBox>.fromOpaque(ptr).takeUnretainedValue().ascent },
            getDescent: { ptr in Unmanaged<ImageBox>.fromOpaque(ptr).takeUnretainedValue().descent },
            getWidth: { ptr in Unmanaged<ImageBox>.fromOpaque(ptr).takeUnretainedValue().width })
        let box = ImageBox(ascent: ascent, descent: descent, width: width)
        return CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(box).toOpaque())
    }

    private static func paragraphStyle(alignment: CTTextAlignment, lineHeight: CGFloat, spacing: CGFloat,
                                       before: CGFloat, headIndent: CGFloat, firstIndent: CGFloat) -> CTParagraphStyle {
        var a = alignment
        var minH = lineHeight
        var maxH = lineHeight
        var sp = spacing
        var bf = before
        var hi = headIndent
        var fi = firstIndent
        return withUnsafePointer(to: &a) { pa in
            withUnsafePointer(to: &minH) { pmin in
                withUnsafePointer(to: &maxH) { pmax in
                    withUnsafePointer(to: &sp) { psp in
                        withUnsafePointer(to: &bf) { pbf in
                            withUnsafePointer(to: &hi) { phi in
                                withUnsafePointer(to: &fi) { pfi in
                                    let settings = [
                                        CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pa),
                                        CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: pmin),
                                        CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: pmax),
                                        CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size, value: psp),
                                        CTParagraphStyleSetting(spec: .paragraphSpacingBefore, valueSize: MemoryLayout<CGFloat>.size, value: pbf),
                                        CTParagraphStyleSetting(spec: .headIndent, valueSize: MemoryLayout<CGFloat>.size, value: phi),
                                        CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: MemoryLayout<CGFloat>.size, value: pfi),
                                    ]
                                    return CTParagraphStyleCreate(settings, settings.count)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func imageSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
              w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Applies fonts, colours and paragraph styles to a semantic chapter string.
    private static func applyStyle(_ rich: NSAttributedString, style: TextStyle, textRect: CGRect) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: rich)
        let full = NSRange(location: 0, length: out.length)
        let fs = style.fontSize
        let baseFont = style.font.uiFont(size: fs)
        let lineH = fs * style.lineSpacing
        let paraSpace = fs * 0.45
        let fg = style.paper.text.cgColor
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let paraKey = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)
        let vertKey = NSAttributedString.Key(kCTVerticalFormsAttributeName as String)
        let isJaText = L10n.isJa || rich.string.unicodeScalars.prefix(400).contains { $0.value >= 0x3040 && $0.value <= 0x30FF }
        let firstIndent: CGFloat = (isJaText && !style.vertical) ? 0 : (style.vertical ? 0 : fs * 1.2)

        out.addAttribute(fontKey, value: baseFont, range: full)
        out.addAttribute(colorKey, value: fg, range: full)
        if style.vertical { out.addAttribute(vertKey, value: true, range: full) }
        out.addAttribute(paraKey, value: paragraphStyle(alignment: style.vertical ? .natural : .justified, lineHeight: lineH,
                                                        spacing: paraSpace, before: 0, headIndent: 0,
                                                        firstIndent: firstIndent), range: full)

        // Paragraph-level attributes are applied per paragraph so headings/quotes get their own spacing.
        let ns = out.string as NSString
        var pos = 0
        while pos < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: pos, length: 0))
            if pr.length == 0 { break }
            let attrs = out.attributes(at: pr.location, effectiveRange: nil)
            let heading = attrs[.duoHeading] as? Int ?? 0
            let center = attrs[.duoCenter] as? Bool ?? false
            let quote = attrs[.duoQuote] as? Bool ?? false
            let pre = attrs[.duoPre] as? Bool ?? false
            if heading > 0 || center || quote || pre || attrs[.duoImage] != nil {
                let scale: CGFloat = heading == 1 ? 1.55 : heading == 2 ? 1.35 : heading == 3 ? 1.2 : heading > 0 ? 1.08 : 1
                let lh = heading > 0 ? fs * scale * max(1.25, style.lineSpacing * 0.9) : lineH
                let ps = paragraphStyle(alignment: (center || heading > 0 && heading <= 2) ? .center : (pre ? .left : .justified),
                                        lineHeight: lh,
                                        spacing: heading > 0 ? fs * 0.9 : paraSpace,
                                        before: heading > 0 ? fs * 1.0 : 0,
                                        headIndent: quote ? fs * 1.5 : 0,
                                        firstIndent: quote ? fs * 1.5 : (center || heading > 0 || pre) ? 0 : firstIndent)
                out.addAttribute(paraKey, value: ps, range: pr)
                if heading > 0 {
                    out.addAttribute(colorKey, value: style.paper.heading.cgColor, range: pr)
                }
            }
            pos = pr.location + pr.length
        }

        // Inline fonts.
        out.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            let bold = attrs[.duoBold] as? Bool ?? false
            let italic = attrs[.duoItalic] as? Bool ?? false
            let heading = attrs[.duoHeading] as? Int ?? 0
            let pre = attrs[.duoPre] as? Bool ?? false
            guard bold || italic || heading > 0 || pre else { return }
            let scale: CGFloat = heading == 1 ? 1.55 : heading == 2 ? 1.35 : heading == 3 ? 1.2 : heading > 0 ? 1.08 : 1
            var font: UIFont
            if pre {
                font = UIFont.monospacedSystemFont(ofSize: fs * 0.88, weight: bold ? .semibold : .regular)
            } else {
                font = style.font.uiFont(size: fs * scale, bold: bold || heading > 0)
            }
            if italic, let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                font = UIFont(descriptor: d, size: fs * scale)
            }
            out.addAttribute(fontKey, value: font, range: range)
        }

        // Images become run delegates that reserve space; the bitmap is drawn after the frame.
        var imageRanges: [(NSRange, URL)] = []
        out.enumerateAttribute(.duoImage, in: full, options: []) { value, range, _ in
            if let u = value as? URL { imageRanges.append((range, u)) }
        }
        for (range, url) in imageRanges.reversed() {
            if style.vertical {
                out.replaceCharacters(in: range, with: "")
                continue
            }
            guard let natural = imageSize(url) else {
                out.replaceCharacters(in: range, with: "")
                continue
            }
            let maxW = textRect.width
            let maxH = textRect.height * 0.82
            var w = min(natural.width * 0.5, maxW)
            var h = natural.height * (w / natural.width)
            if h > maxH { h = maxH; w = natural.width * (h / natural.height) }
            if let d = runDelegate(ascent: h, descent: 0, width: w) {
                out.addAttribute(NSAttributedString.Key(kCTRunDelegateAttributeName as String), value: d, range: range)
            }
        }
        return out
    }

    // MARK: - Rendering

    func render(page: Int, size: CGSize, scale: CGFloat, style: TextStyle) -> CGImage? {
        prepare(pageSize: size, style: style)
        guard page >= 0, page < pages.count else { return nil }
        let ref = pages[page]
        let met = metrics(for: size, style: style)
        let W = Int(size.width * scale), H = Int(size.height * scale)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(style.paper.background.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        drawPaperTexture(ctx, size: size, style: style)

        // CoreText draws with a y-up origin; the text rect is expressed top-left so convert.
        let tr = met.textRect
        let rectCT = CGRect(x: tr.minX, y: size.height - tr.maxY, width: tr.width, height: tr.height)
        let path = CGPath(rect: rectCT, transform: nil)
        let fs = framesetters[ref.chapter]
        let frame = CTFramesetterCreateFrame(fs, ref.range, path, Self.frameAttributes(vertical: style.vertical))
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        if !style.vertical { drawImages(in: frame, ctx: ctx) }

        // Running head and folio.
        let muted = style.paper.muted
        let small = style.font.uiFont(size: max(9, style.fontSize * 0.62))
        let chapterTitle = chapterTexts[ref.chapter].title
        let head = chapterTexts.count > 1 && chapterTitle != bookTitle ? chapterTitle : bookTitle
        drawLine(head, font: small, color: muted, ctx: ctx, at: CGPoint(x: tr.minX, y: size.height - met.headerY - small.ascender * 0.5), maxWidth: tr.width, align: .left)
        drawLine("\(page + 1)", font: small, color: muted, ctx: ctx, at: CGPoint(x: size.width / 2, y: size.height - met.footerY - small.ascender * 0.5), maxWidth: 80, align: .center)
        return ctx.makeImage()
    }

    private func drawPaperTexture(_ ctx: CGContext, size: CGSize, style: TextStyle) {
        let v = style.paper.vignette
        guard v > 0 else { return }
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [UIColor.clear.cgColor, UIColor(red: 0.35, green: 0.22, blue: 0.08, alpha: v).cgColor] as CFArray
        guard let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0.45, 1.0]) else { return }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: max(size.width, size.height) * 0.75, options: [.drawsAfterEndLocation])
    }

    private func drawLine(_ text: String, font: UIFont, color: UIColor, ctx: CGContext, at: CGPoint, maxWidth: CGFloat, align: CTTextAlignment) {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        var line = CTLineCreateWithAttributedString(s as CFAttributedString)
        if let truncated = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, nil) { line = truncated }
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        var x = at.x
        if align == .center { x -= w / 2 }
        ctx.textPosition = CGPoint(x: x, y: at.y)
        CTLineDraw(line, ctx)
    }

    private func drawImages(in frame: CTFrame, ctx: CGContext) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let path = CTFrameGetPath(frame)
        let box = path.boundingBox
        for (i, line) in lines.enumerated() {
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            for run in runs {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                guard let url = attrs[NSAttributedString.Key.duoImage.rawValue] as? URL else { continue }
                var ascent: CGFloat = 0, descent: CGFloat = 0
                let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil))
                var pos = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &pos)
                let rect = CGRect(x: box.minX + origins[i].x + pos.x, y: box.minY + origins[i].y - descent, width: width, height: ascent + descent)
                if let img = image(for: url, maxPixel: max(rect.width, rect.height) * 3) {
                    ctx.saveGState()
                    ctx.interpolationQuality = .high
                    ctx.draw(img, in: rect)
                    ctx.restoreGState()
                }
            }
        }
    }

    private func image(for url: URL, maxPixel: CGFloat) -> CGImage? {
        if let c = imageCache[url] { return c }
        let img = ImageLoader.downsampled(url, maxPixel: min(2400, maxPixel))?.cgImage
        if let img { imageCache[url] = img }
        if imageCache.count > 24 { imageCache.removeAll() }
        return img
    }

    // MARK: - Search

    func search(_ query: String) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !pages.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for (ci, ch) in chapterTexts.enumerated() {
            let s = ch.plain as NSString
            var searchRange = NSRange(location: 0, length: s.length)
            while searchRange.location < s.length {
                let r = s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                if r.location == NSNotFound { break }
                let global = chapterOffsets[ci] + r.location
                let pg = page(forOffset: global)
                let a = max(0, r.location - 24)
                let b = min(s.length, r.location + r.length + 40)
                let snippet = s.substring(with: NSRange(location: a, length: b - a))
                    .replacingOccurrences(of: "\n", with: " ")
                hits.append(SearchHit(page: pg, snippet: (a > 0 ? "…" : "") + snippet + (b < s.length ? "…" : "")))
                if hits.count >= 300 { return hits }
                searchRange = NSRange(location: r.location + max(1, r.length), length: s.length - (r.location + max(1, r.length)))
            }
        }
        return hits
    }
}
