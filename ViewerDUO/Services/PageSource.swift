import Foundation
import UIKit
import PDFKit
import ImageIO

/// A book opened for reading. All rendering methods are called off the main thread on a serial queue,
/// so implementations do not need their own locking as long as they keep state private.
protocol PageSource: AnyObject {
    var pageCount: Int { get }
    var chapters: [Chapter] { get }
    /// Height divided by width of a page.
    var aspect: CGFloat { get }
    var isReflowable: Bool { get }
    var supportsSearch: Bool { get }

    /// Reflowable sources lay their text out for the given page size and style. Others ignore this.
    func prepare(pageSize: CGSize, style: TextStyle)
    /// Renders one page into a bitmap of `size` points at `scale`. Returns nil for out-of-range pages.
    func render(page: Int, size: CGSize, scale: CGFloat, style: TextStyle) -> CGImage?
    /// Character offset of the first character on `page` (reflowable only; 0 otherwise).
    func offset(forPage page: Int) -> Int
    /// Page containing character `offset` (reflowable only; `offset` is treated as a page index otherwise).
    func page(forOffset offset: Int) -> Int
    func search(_ query: String) -> [SearchHit]
}

extension PageSource {
    func offset(forPage page: Int) -> Int { page }
    func page(forOffset offset: Int) -> Int { offset }
    func prepare(pageSize: CGSize, style: TextStyle) {}
    func search(_ query: String) -> [SearchHit] { [] }
    var supportsSearch: Bool { false }
}

enum PageRasterizer {
    /// Draws `image` fitted inside a page of `size` on top of the paper colour.
    static func fitted(image: CGImage?, size: CGSize, scale: CGFloat, paper: UIColor) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let out = renderer.image { ctx in
            paper.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            guard let image else { return }
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            guard iw > 0, ih > 0 else { return }
            let s = min(size.width / iw, size.height / ih)
            let w = iw * s, h = ih * s
            let rect = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
            ctx.cgContext.interpolationQuality = .high
            UIImage(cgImage: image).draw(in: rect)
        }
        return out.cgImage
    }
}

// MARK: - PDF

final class PDFSource: PageSource {
    private let doc: PDFDocument
    let pageCount: Int
    let chapters: [Chapter]
    let aspect: CGFloat
    var isReflowable: Bool { false }
    var supportsSearch: Bool { true }

    init?(url: URL) {
        guard let d = PDFDocument(url: url), d.pageCount > 0 else { return nil }
        doc = d
        pageCount = d.pageCount
        if let p = d.page(at: 0) {
            let b = p.bounds(for: .cropBox)
            let rotated = (p.rotation % 180) != 0
            let w = rotated ? b.height : b.width
            let h = rotated ? b.width : b.height
            aspect = (w > 0 && h > 0) ? h / w : 1.414
        } else {
            aspect = 1.414
        }
        chapters = Self.outline(d)
    }

    private static func outline(_ doc: PDFDocument) -> [Chapter] {
        guard let root = doc.outlineRoot else { return [] }
        var out: [Chapter] = []
        func walk(_ n: PDFOutline, depth: Int) {
            for i in 0..<n.numberOfChildren {
                guard let c = n.child(at: i) else { continue }
                if let pg = c.destination?.page, let label = c.label, !label.isEmpty {
                    out.append(Chapter(title: label, page: doc.index(for: pg), depth: depth))
                }
                if depth < 2 { walk(c, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return out
    }

    func render(page: Int, size: CGSize, scale: CGFloat, style: TextStyle) -> CGImage? {
        guard page >= 0, page < pageCount, let p = doc.page(at: page) else { return nil }
        let px = CGSize(width: size.width * scale, height: size.height * scale)
        let thumb = p.thumbnail(of: px, for: .cropBox)
        // PDF pages are white by design; only the letterbox picks up the paper colour.
        let paper = style.paper.isDark ? UIColor(white: 0.16, alpha: 1) : style.paper.background
        return PageRasterizer.fitted(image: thumb.cgImage, size: size, scale: scale, paper: paper)
    }

    func search(_ query: String) -> [SearchHit] {
        let sels = doc.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        var hits: [SearchHit] = []
        var seen: [Int: Int] = [:]
        for s in sels.prefix(400) {
            guard let pg = s.pages.first else { continue }
            let idx = doc.index(for: pg)
            if seen[idx, default: 0] >= 3 { continue }
            seen[idx, default: 0] += 1
            let ext = s.copy() as? PDFSelection
            ext?.extend(atStart: 30)
            ext?.extend(atEnd: 40)
            let snippet = (ext?.string ?? s.string ?? "").replacingOccurrences(of: "\n", with: " ")
            hits.append(SearchHit(page: idx, snippet: snippet.trimmingCharacters(in: .whitespaces)))
        }
        return hits
    }
}

// MARK: - Image archives (ZIP / RAR)

final class ImageSource: PageSource {
    private let urls: [URL]
    let pageCount: Int
    let chapters: [Chapter] = []
    let aspect: CGFloat
    var isReflowable: Bool { false }

    init(urls: [URL]) {
        self.urls = urls
        pageCount = urls.count
        var a: CGFloat = 1.42
        if let first = urls.first, let src = CGImageSourceCreateWithURL(first as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
           w > 0, h > 0 {
            a = h / w
        }
        aspect = min(max(a, 0.6), 2.2)
    }

    func render(page: Int, size: CGSize, scale: CGFloat, style: TextStyle) -> CGImage? {
        guard page >= 0, page < pageCount else { return nil }
        let maxPx = max(size.width, size.height) * scale
        let img = ImageLoader.downsampled(urls[page], maxPixel: maxPx)
        let paper = style.paper.isDark ? UIColor(white: 0.12, alpha: 1) : style.paper.background
        return PageRasterizer.fitted(image: img?.cgImage, size: size, scale: scale, paper: paper)
    }
}
