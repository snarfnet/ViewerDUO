import Foundation

// MARK: - Tiny XML tree

final class DVXMLNode {
    enum Piece {
        case text(String)
        case child(DVXMLNode)
    }

    let name: String
    let attributes: [String: String]
    var children: [DVXMLNode] = []
    /// Text and child elements in document order (needed to rebuild inline runs faithfully).
    var pieces: [Piece] = []
    var text: String = ""
    weak var parent: DVXMLNode?

    init(name: String, attributes: [String: String], parent: DVXMLNode?) {
        self.name = name
        self.attributes = attributes
        self.parent = parent
    }

    func first(_ name: String) -> DVXMLNode? {
        if self.name == name { return self }
        for c in children { if let f = c.first(name) { return f } }
        return nil
    }

    func all(_ name: String) -> [DVXMLNode] {
        var out: [DVXMLNode] = []
        if self.name == name { out.append(self) }
        for c in children { out.append(contentsOf: c.all(name)) }
        return out
    }

    func attr(_ key: String) -> String? {
        if let v = attributes[key] { return v }
        for (k, v) in attributes where k.hasSuffix(":" + key) { return v }
        return nil
    }
}

final class DVXMLTreeParser: NSObject, XMLParserDelegate {
    private var root: DVXMLNode?
    private var current: DVXMLNode?

    static func parse(_ data: Data) -> DVXMLNode? {
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = true
        p.shouldResolveExternalEntities = false
        let d = DVXMLTreeParser()
        p.delegate = d
        p.parse()
        return d.root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = DVXMLNode(name: elementName, attributes: attributeDict, parent: current)
        if let c = current {
            c.children.append(node)
            c.pieces.append(.child(node))
        } else {
            root = node
        }
        current = node
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let c = current else { return }
        c.text += string
        if case .text(let prev)? = c.pieces.last {
            c.pieces[c.pieces.count - 1] = .text(prev + string)
        } else {
            c.pieces.append(.text(string))
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: s) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        current = current?.parent
    }
}

// MARK: - EPUB

struct EPUBPackage {
    let title: String?
    let author: String?
    let spine: [URL]
    let chapterTitles: [String]
    let rootDir: URL
    /// Spine indices that have a real title in the NCX / nav document.
    var labeledSpine: [Int: String] = [:]
    var coverImage: URL?
    /// page-progression-direction="rtl" (Japanese manga and vertical novels).
    var rightToLeft = false
    /// Set when every spine document is just one picture (fixed-layout manga / photo books).
    var imagePages: [URL]?
}

enum EPUBError: Error {
    case noContainer
    case noOPF
    case emptySpine
}

enum EPUBParser {
    static func open(fileURL: URL, bookID: UUID) throws -> EPUBPackage {
        let dir = Library.cacheDir(for: bookID)
        let marker = dir.appendingPathComponent(".extracted")
        if !FileManager.default.fileExists(atPath: marker.path) {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let zip = try MiniZip(url: fileURL)
            for e in zip.entries where !e.isDirectory {
                guard let rel = ArchiveExtractor.safeRelativePath(e.name) else { continue }
                let out = dir.appendingPathComponent(rel)
                try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let d = try? zip.extract(e) { try d.write(to: out) }
            }
            try Data().write(to: marker)
        }

        // container.xml -> OPF path
        var opfURL: URL?
        let containerURL = dir.appendingPathComponent("META-INF/container.xml")
        if let cdata = try? Data(contentsOf: containerURL),
           let croot = DVXMLTreeParser.parse(cdata),
           let rf = croot.first("rootfile"),
           let path = rf.attr("full-path") {
            opfURL = dir.appendingPathComponent(path)
        }
        if opfURL == nil {
            // fall back: search for any .opf
            if let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
                for case let u as URL in en where u.pathExtension.lowercased() == "opf" {
                    opfURL = u
                    break
                }
            }
        }
        guard let opf = opfURL, let odata = try? Data(contentsOf: opf),
              let oroot = DVXMLTreeParser.parse(odata) else { throw EPUBError.noOPF }
        let opfDir = opf.deletingLastPathComponent()

        let title = oroot.all("title").first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = oroot.all("creator").first?.text.trimmingCharacters(in: .whitespacesAndNewlines)

        var manifest: [String: (href: String, type: String, props: String)] = [:]
        for item in oroot.all("item") {
            guard let id = item.attr("id"), let href = item.attr("href") else { continue }
            manifest[id] = (href, item.attr("media-type") ?? "", item.attr("properties") ?? "")
        }

        func resolve(_ href: String) -> URL {
            let cleaned = href.components(separatedBy: "#").first ?? href
            let decoded = cleaned.removingPercentEncoding ?? cleaned
            return URL(fileURLWithPath: decoded, relativeTo: opfDir).standardizedFileURL
        }

        var spine: [URL] = []
        for ref in oroot.all("itemref") {
            guard let idref = ref.attr("idref"), let item = manifest[idref] else { continue }
            if ref.attr("linear") == "no" { continue }
            spine.append(resolve(item.href))
        }
        if spine.isEmpty {
            for (_, item) in manifest where item.type.contains("xhtml") || item.type.contains("html") {
                spine.append(resolve(item.href))
            }
            spine.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        guard !spine.isEmpty else { throw EPUBError.emptySpine }

        // Chapter titles from NCX or nav document
        var labelByPath: [String: String] = [:]
        var ncxHref: String?
        if let spineNode = oroot.first("spine"), let tocID = spineNode.attr("toc"), let item = manifest[tocID] {
            ncxHref = item.href
        } else if let ncx = manifest.values.first(where: { $0.type.contains("dtbncx") }) {
            ncxHref = ncx.href
        }
        if let h = ncxHref, let ndata = try? Data(contentsOf: resolve(h)), let nroot = DVXMLTreeParser.parse(ndata) {
            for np in nroot.all("navPoint") {
                let label = np.first("text")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let src = np.first("content")?.attr("src") {
                    let key = resolve(src).path
                    if labelByPath[key] == nil, !label.isEmpty { labelByPath[key] = label }
                }
            }
        }
        if labelByPath.isEmpty, let nav = manifest.values.first(where: { $0.props.contains("nav") }),
           let ndata = try? Data(contentsOf: resolve(nav.href)), let nroot = DVXMLTreeParser.parse(ndata) {
            let navDir = resolve(nav.href).deletingLastPathComponent()
            for a in nroot.all("a") {
                guard let href = a.attr("href") else { continue }
                let cleaned = (href.components(separatedBy: "#").first ?? href).removingPercentEncoding ?? href
                let key = URL(fileURLWithPath: cleaned, relativeTo: navDir).standardizedFileURL.path
                let label = flatText(a).trimmingCharacters(in: .whitespacesAndNewlines)
                if labelByPath[key] == nil, !label.isEmpty { labelByPath[key] = label }
            }
        }
        let titles: [String] = spine.enumerated().map { i, u in
            labelByPath[u.path] ?? String(format: L10n.chapterN, i + 1)
        }
        var pkg = EPUBPackage(title: title, author: author, spine: spine, chapterTitles: titles, rootDir: dir)
        for (i, u) in spine.enumerated() { if let l = labelByPath[u.path] { pkg.labeledSpine[i] = l } }
        pkg.rightToLeft = oroot.first("spine")?.attr("page-progression-direction")?.lowercased() == "rtl"

        // Cover: EPUB 3 "cover-image" property, then the EPUB 2 <meta name="cover"> id.
        if let c = manifest.values.first(where: { $0.props.contains("cover-image") }) {
            pkg.coverImage = resolve(c.href)
        } else if let meta = oroot.all("meta").first(where: { $0.attr("name") == "cover" }),
                  let cid = meta.attr("content"), let item = manifest[cid], item.type.hasPrefix("image") {
            pkg.coverImage = resolve(item.href)
        }

        let fixedLayout = oroot.all("meta").contains { m in
            (m.attr("property") == "rendition:layout" && m.text.trimmingCharacters(in: .whitespacesAndNewlines) == "pre-paginated")
                || (m.attr("name") == "fixed-layout" && m.attr("content") == "true")
        }
        let pictures = spine.map { singlePicture(in: $0) }
        let found = pictures.compactMap { $0 }
        // Most manga EPUBs are entirely one picture per page; allow a couple of text pages (credits, colophon).
        if !found.isEmpty, (fixedLayout && found.count * 10 >= spine.count * 7) || found.count * 10 >= spine.count * 9 {
            pkg.imagePages = found
            if pkg.coverImage == nil { pkg.coverImage = found.first }
        }
        if let c = pkg.coverImage, !FileManager.default.fileExists(atPath: c.path) { pkg.coverImage = nil }
        return pkg
    }

    private static let pictureExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "tif", "tiff", "avif"]

    /// The image a spine document shows when it holds almost no text, or nil for a normal text page.
    static func singlePicture(in doc: URL) -> URL? {
        if pictureExtensions.contains(doc.pathExtension.lowercased()) {
            return FileManager.default.fileExists(atPath: doc.path) ? doc : nil
        }
        guard let data = try? Data(contentsOf: doc), let raw = String(data: data, encoding: .utf8) else { return nil }
        var body = raw
        if let r = raw.range(of: "<body", options: .caseInsensitive) { body = String(raw[r.lowerBound...]) }
        let pattern = #"<(?:img|image)\b[^>]*?(?:src|xlink:href|href)\s*=\s*["']([^"']+)["']"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = body as NSString
        let matches = re.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard matches.count == 1, let m = matches.first else { return nil }
        let text = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&[a-zA-Z#0-9]+;", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count < 40 else { return nil }
        let src = ns.substring(with: m.range(at: 1))
        let cleaned = (src.components(separatedBy: "#").first ?? src).removingPercentEncoding ?? src
        let u = URL(fileURLWithPath: cleaned, relativeTo: doc.deletingLastPathComponent()).standardizedFileURL
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private static func flatText(_ n: DVXMLNode) -> String {
        var s = n.text
        for c in n.children { s += flatText(c) }
        return s
    }
}
