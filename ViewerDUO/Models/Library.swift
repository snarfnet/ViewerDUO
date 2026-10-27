import Foundation
import UIKit
import PDFKit

@MainActor
final class Library: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published var coverVersion = 0

    nonisolated static let booksDir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    nonisolated static let cacheRoot: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Extracted", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    nonisolated static let coversDir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    nonisolated static func cacheDir(for id: UUID) -> URL {
        cacheRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    nonisolated static func coverURL(for id: UUID) -> URL {
        coversDir.appendingPathComponent(id.uuidString + ".jpg")
    }

    private var indexURL: URL { Self.booksDir.appendingPathComponent("library.json") }

    init() {
        load()
        if ScreenshotMode.isActive {
            seedDemo()
        } else if !UserDefaults.standard.bool(forKey: "seededSample") {
            UserDefaults.standard.set(true, forKey: "seededSample")
            if books.isEmpty {
                seedSampleBook(title: L10n.t("Viewer DUO の使い方", "How to use Viewer DUO"), author: L10n.sample)
            }
        }
        if !ScreenshotMode.isActive { restoreMissingCovers() }
    }

    func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Book].self, from: data) else { return }
        books = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(books) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    func fileURL(for book: Book) -> URL { Self.booksDir.appendingPathComponent(book.fileName) }

    func sorted(by order: String) -> [Book] {
        switch order {
        case "title": return books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case "added": return books.sorted { $0.addedAt > $1.addedAt }
        default: return books.sorted { ($0.lastOpened ?? $0.addedAt) > ($1.lastOpened ?? $1.addedAt) }
        }
    }

    var mostRecent: Book? {
        books.filter { $0.lastOpened != nil }.max { ($0.lastOpened ?? .distantPast) < ($1.lastOpened ?? .distantPast) }
    }

    /// True while files are being copied in; the library shows a progress card.
    @Published private(set) var importing = false
    /// A book the app was asked to open from outside (share sheet / Files "Open in").
    @Published var pendingOpen: Book?

    /// Imports files and folders off the main thread. Several image files picked together become one book.
    @discardableResult
    func importFiles(_ urls: [URL]) async -> (books: [Book], failed: Int) {
        guard !urls.isEmpty else { return ([], 0) }
        importing = true
        defer { importing = false }
        let result = await Task.detached(priority: .userInitiated) { () -> ([Book], Int) in
            var made: [Book] = []
            var failed = 0
            var loose: [URL] = []
            for u in urls {
                if Library.isDirectory(u) {
                    if let b = Library.importImageFolder(u) { made.append(b) } else { failed += 1 }
                } else if ArchiveExtractor.imageExtensions.contains(u.pathExtension.lowercased()) {
                    loose.append(u)
                } else if let b = Library.importDocument(u) {
                    made.append(b)
                } else {
                    failed += 1
                }
            }
            if !loose.isEmpty {
                if let b = Library.importImageFiles(loose) { made.append(b) } else { failed += 1 }
            }
            return (made, failed)
        }.value
        for b in result.0 {
            books.insert(b, at: 0)
            CoverStore.shared.generate(for: b, fileURL: fileURL(for: b)) { [weak self] in self?.coverVersion += 1 }
        }
        if !result.0.isEmpty { save() }
        return (result.0, result.1)
    }

    /// Opened from another app: import, then open the book straight away.
    @discardableResult
    func importAndOpen(_ url: URL) async -> Bool {
        let r = await importFiles([url])
        if let b = r.books.first { pendingOpen = b }
        return r.failed == 0
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? url.hasDirectoryPath
    }

    /// Copies a file that may still live only in iCloud; the coordinator downloads it first.
    nonisolated private static func coordinatedCopy(_ src: URL, to dst: URL) -> Bool {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        var ok = false
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: src, options: [.withoutChanges], error: &err) { readURL in
            try? FileManager.default.removeItem(at: dst)
            ok = (try? FileManager.default.copyItem(at: readURL, to: dst)) != nil
        }
        // Files handed over through "Open in" sit in Documents/Inbox; tidy them once copied.
        if ok, src.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: src) }
        return ok
    }

    nonisolated private static func importDocument(_ src: URL) -> Book? {
        guard let format = BookFormat.from(ext: src.pathExtension) else { return nil }
        let id = UUID()
        let fileName = id.uuidString + "." + src.pathExtension.lowercased()
        let dst = booksDir.appendingPathComponent(fileName)
        guard coordinatedCopy(src, to: dst) else { return nil }
        var title = src.deletingPathExtension().lastPathComponent
        var author = ""
        var pageCount = 0
        var rtl: Bool?
        func fail() -> Book? {
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.removeItem(at: cacheDir(for: id))
            return nil
        }
        switch format {
        case .pdf:
            guard let doc = PDFDocument(url: dst), doc.pageCount > 0 else { return fail() }
            pageCount = doc.pageCount
            if let t = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
               !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                title = t
            }
            if let a = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String {
                author = a.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case .epub:
            guard let pkg = try? EPUBParser.open(fileURL: dst, bookID: id) else { return fail() }
            pageCount = pkg.imagePages?.count ?? pkg.spine.count
            if let t = pkg.title, !t.isEmpty { title = t }
            if let a = pkg.author { author = a }
            if pkg.rightToLeft { rtl = true }
        case .zip, .rar:
            guard let pages = try? ArchiveExtractor.imagePages(fileURL: dst, format: format, bookID: id) else { return fail() }
            pageCount = pages.count
        case .txt, .images:
            break
        }
        return Book(id: id, title: title, author: author, fileName: fileName, format: format, addedAt: Date(),
                    pageCount: pageCount, rightToLeft: rtl)
    }

    /// A picked folder of numbered images becomes one book (sub-folders included, natural order).
    nonisolated private static func importImageFolder(_ src: URL) -> Book? {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        var book: Book?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: src, options: [.withoutChanges], error: &err) { dir in
            book = makeImageBook(from: ArchiveExtractor.listImages(in: dir), title: src.lastPathComponent, coordinated: true)
        }
        return book
    }

    nonisolated private static func importImageFiles(_ files: [URL]) -> Book? {
        let sorted = files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let parent = sorted.first?.deletingLastPathComponent().lastPathComponent ?? ""
        let generic: Set<String> = ["", "tmp", "Inbox", "Downloads", "Documents", "Pictures"]
        let title = generic.contains(parent) || parent.hasPrefix("com.") || parent.contains("-Inbox")
            ? (sorted.first?.deletingPathExtension().lastPathComponent ?? L10n.imageBook) : parent
        return makeImageBook(from: sorted, title: title, coordinated: false)
    }

    nonisolated private static func makeImageBook(from files: [URL], title: String, coordinated: Bool) -> Book? {
        guard !files.isEmpty else { return nil }
        let id = UUID()
        let dir = booksDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Zero-padded names keep the picked order no matter how the originals were numbered.
        var n = 0
        for f in files {
            let dst = dir.appendingPathComponent(String(format: "%05d.", n + 1) + f.pathExtension.lowercased())
            let ok = coordinated ? (try? FileManager.default.copyItem(at: f, to: dst)) != nil : coordinatedCopy(f, to: dst)
            if ok { n += 1 }
        }
        guard n > 0 else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        return Book(id: id, title: title, author: "", fileName: id.uuidString, format: .images, addedAt: Date(), pageCount: n)
    }

    /// Covers live in Caches, which iOS may purge; rebuild any that went missing.
    private func restoreMissingCovers() {
        for b in books where !FileManager.default.fileExists(atPath: Self.coverURL(for: b.id).path) {
            CoverStore.shared.generate(for: b, fileURL: fileURL(for: b)) { [weak self] in self?.coverVersion += 1 }
        }
    }

    func delete(_ book: Book) {
        try? FileManager.default.removeItem(at: fileURL(for: book))
        try? FileManager.default.removeItem(at: Self.cacheDir(for: book.id))
        try? FileManager.default.removeItem(at: Self.coverURL(for: book.id))
        books.removeAll { $0.id == book.id }
        save()
    }

    func rename(_ book: Book, title: String, author: String) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        books[i].title = t
        books[i].author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
        if book.format.isReflowable {
            CoverStore.shared.generate(for: books[i], fileURL: fileURL(for: book)) { [weak self] in self?.coverVersion += 1 }
        }
    }

    func markOpened(_ book: Book) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[i].lastOpened = Date()
        save()
    }

    func update(_ book: Book, page: Int, offset: Int, pageCount: Int? = nil) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[i].lastPage = page
        books[i].lastOffset = offset
        if let pc = pageCount, pc > 0 { books[i].pageCount = pc }
        save()
    }

    func setOverrides(_ book: Book, rightToLeft: Bool?, verticalText: Bool?) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[i].rightToLeft = rightToLeft
        books[i].verticalText = verticalText
        save()
    }

    func setTurnStyle(_ book: Book, _ style: String?) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[i].turnStyle = style
        save()
    }

    func toggleBookmark(_ book: Book, page: Int, offset: Int, label: String) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        if let idx = books[i].bookmarks.firstIndex(where: { book.format.isReflowable ? $0.offset == offset : $0.page == page }) {
            books[i].bookmarks.remove(at: idx)
        } else {
            books[i].bookmarks.append(Bookmark(id: UUID(), page: page, offset: offset, label: label, createdAt: Date()))
            books[i].bookmarks.sort { $0.offset != $1.offset ? $0.offset < $1.offset : $0.page < $1.page }
        }
        save()
    }

    func removeBookmark(_ book: Book, id: UUID) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[i].bookmarks.removeAll { $0.id == id }
        save()
    }

    func book(withID id: UUID) -> Book? { books.first { $0.id == id } }

    // MARK: - Sample / demo

    private func sampleTextURL() -> URL? {
        let name = L10n.isJa ? "sample_ja" : "sample_en"
        return Bundle.main.url(forResource: name, withExtension: "txt")
    }

    @discardableResult
    private func seedSampleBook(title: String, author: String, page: Int = 0) -> Book? {
        guard let src = sampleTextURL() else { return nil }
        let id = UUID()
        let fileName = id.uuidString + ".txt"
        let dst = Self.booksDir.appendingPathComponent(fileName)
        try? FileManager.default.copyItem(at: src, to: dst)
        let book = Book(id: id, title: title, author: author, fileName: fileName, format: .txt, addedAt: Date(), lastPage: page)
        books.append(book)
        save()
        CoverStore.shared.generate(for: book, fileURL: dst) { [weak self] in self?.coverVersion += 1 }
        return book
    }

    private func seedDemo() {
        for b in books { delete(b) }
        let titles: [(String, String)] = L10n.isJa
            ? [("Viewer DUO の使い方", "サンプル"), ("吾輩は猫である", "夏目漱石"), ("走れメロス", "太宰治"), ("銀河鉄道の夜", "宮沢賢治"),
               ("羅生門", "芥川龍之介"), ("こころ", "夏目漱石"), ("注文の多い料理店", "宮沢賢治"), ("蜘蛛の糸", "芥川龍之介"), ("人間失格", "太宰治")]
            : [("How to use Viewer DUO", "Sample"), ("Pride and Prejudice", "Jane Austen"), ("Moby-Dick", "Herman Melville"),
               ("The Great Gatsby", "F. Scott Fitzgerald"), ("Dracula", "Bram Stoker"), ("Jane Eyre", "Charlotte Brontë"),
               ("Frankenstein", "Mary Shelley"), ("The Odyssey", "Homer"), ("Walden", "Henry David Thoreau")]
        for (i, t) in titles.enumerated() {
            seedSampleBook(title: t.0, author: t.1, page: 0)
            if i > 0 {
                books[books.count - 1].pageCount = 42
                books[books.count - 1].lastPage = (i * 7) % 42
                books[books.count - 1].lastOpened = Date().addingTimeInterval(-Double(i) * 3600)
            }
        }
        if ScreenshotMode.target == "slide", let b = Self.demoImageBook() {
            books.insert(b, at: 0)
            CoverStore.shared.generate(for: b, fileURL: fileURL(for: b)) { [weak self] in self?.coverVersion += 1 }
        }
        save()
    }

    /// Numbered picture pages for the slide-mode screenshot.
    private static func demoImageBook() -> Book? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("demo-images", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        var files: [URL] = []
        let size = CGSize(width: 700, height: 1000)
        for i in 1...10 {
            let hue = CGFloat(i) / 10.0
            let img = UIGraphicsImageRenderer(size: size).image { ctx in
                let cg = ctx.cgContext
                let top = UIColor(hue: hue, saturation: 0.45, brightness: 0.95, alpha: 1)
                let bottom = UIColor(hue: hue + 0.08, saturation: 0.65, brightness: 0.55, alpha: 1)
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
                    cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
                }
                UIColor(white: 1, alpha: 0.85).setFill()
                cg.fillEllipse(in: CGRect(x: 150, y: 260, width: 400, height: 400))
                let para = NSMutableParagraphStyle()
                para.alignment = .center
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 220, weight: .heavy),
                                                            .foregroundColor: bottom, .paragraphStyle: para]
                ("\(i)" as NSString).draw(in: CGRect(x: 0, y: 330, width: size.width, height: 280), withAttributes: attrs)
            }
            let u = tmp.appendingPathComponent(String(format: "page_%02d.jpg", i))
            if let d = img.jpegData(compressionQuality: 0.9) { try? d.write(to: u); files.append(u) }
        }
        return makeImageBook(from: files, title: L10n.t("連番画像サンプル", "Numbered images"), coordinated: true)
    }
}

// MARK: - Cover thumbnails

final class CoverStore {
    static let shared = CoverStore()
    private let queue = DispatchQueue(label: "duo.covers", qos: .utility)
    private var memory: [UUID: UIImage] = [:]
    private let lock = NSLock()

    func image(for id: UUID) -> UIImage? {
        lock.lock()
        if let m = memory[id] { lock.unlock(); return m }
        lock.unlock()
        guard let img = UIImage(contentsOfFile: Library.coverURL(for: id).path) else { return nil }
        lock.lock()
        memory[id] = img
        lock.unlock()
        return img
    }

    func generate(for book: Book, fileURL: URL, completion: @escaping () -> Void) {
        queue.async {
            let size = CGSize(width: 240, height: 340)
            var image: UIImage?
            switch book.format {
            case .pdf:
                if let src = PDFSource(url: fileURL) {
                    let h = size.width * src.aspect
                    let style = TextStyle(paper: PaperStyle.named("white"), font: .serif, fontSize: 14, lineSpacing: 1.6, margin: 1, vertical: false)
                    if let cg = src.render(page: 0, size: CGSize(width: size.width, height: min(h, 480)), scale: 2, style: style) {
                        image = UIImage(cgImage: cg)
                    }
                }
            case .zip, .rar, .images:
                let pages = book.format == .images ? ArchiveExtractor.listImages(in: fileURL)
                    : ((try? ArchiveExtractor.imagePages(fileURL: fileURL, format: book.format, bookID: book.id)) ?? [])
                if let first = pages.first {
                    image = Self.pictureCover(first, width: size.width)
                }
            case .epub:
                if let pkg = try? EPUBParser.open(fileURL: fileURL, bookID: book.id), let c = pkg.coverImage {
                    image = Self.pictureCover(c, width: size.width)
                }
                if image == nil {
                    image = Self.designedCover(title: book.title, author: book.author, hue: book.hue, size: size)
                }
            case .txt:
                image = Self.designedCover(title: book.title, author: book.author, hue: book.hue, size: size)
            }
            if let image, let data = image.jpegData(compressionQuality: 0.85) {
                try? data.write(to: Library.coverURL(for: book.id), options: .atomic)
                self.lock.lock()
                self.memory[book.id] = image
                self.lock.unlock()
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    private static func pictureCover(_ url: URL, width: CGFloat) -> UIImage? {
        let src = ImageSource(urls: [url])
        let style = TextStyle(paper: PaperStyle.named("white"), font: .serif, fontSize: 14, lineSpacing: 1.6, margin: 1, vertical: false)
        guard let cg = src.render(page: 0, size: CGSize(width: width, height: width * src.aspect), scale: 2, style: style) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// A cloth-bound cover with a paper label, coloured from the book's hue.
    static func designedCover(title: String, author: String, hue: Double, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let base = UIColor(hue: hue, saturation: 0.42, brightness: 0.40, alpha: 1)
            let dark = UIColor(hue: hue, saturation: 0.50, brightness: 0.26, alpha: 1)
            let cs = CGColorSpaceCreateDeviceRGB()
            if let g = CGGradient(colorsSpace: cs, colors: [base.cgColor, dark.cgColor] as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size.width, y: size.height), options: [])
            }
            // Cloth weave.
            cg.setStrokeColor(UIColor(white: 0, alpha: 0.06).cgColor)
            cg.setLineWidth(1)
            var y: CGFloat = 0
            while y < size.height { cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: size.width, y: y)); y += 3 }
            cg.strokePath()
            // Spine band.
            cg.setFillColor(UIColor(white: 0, alpha: 0.18).cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: 14, height: size.height))
            cg.setFillColor(UIColor(white: 1, alpha: 0.10).cgColor)
            cg.fill(CGRect(x: 14, y: 0, width: 2, height: size.height))
            // Paper label.
            let label = CGRect(x: 34, y: 54, width: size.width - 60, height: size.height * 0.46)
            cg.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: UIColor(white: 0, alpha: 0.35).cgColor)
            cg.setFillColor(UIColor(red: 0.96, green: 0.93, blue: 0.86, alpha: 1).cgColor)
            cg.fill(label)
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            cg.setStrokeColor(UIColor(hue: hue, saturation: 0.35, brightness: 0.45, alpha: 0.6).cgColor)
            cg.setLineWidth(1.5)
            cg.stroke(label.insetBy(dx: 5, dy: 5))

            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineBreakMode = .byWordWrapping
            let titleFont = L10n.isJa ? (UIFont(name: "HiraMinProN-W6", size: 19) ?? UIFont.systemFont(ofSize: 19, weight: .semibold))
                                      : FontChoice.serif.uiFont(size: 19, bold: true)
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .paragraphStyle: para,
                                                             .foregroundColor: UIColor(red: 0.18, green: 0.13, blue: 0.09, alpha: 1)]
            let titleRect = label.insetBy(dx: 12, dy: 14)
            let ns = title as NSString
            let bound = ns.boundingRect(with: CGSize(width: titleRect.width, height: 1000), options: [.usesLineFragmentOrigin], attributes: titleAttrs, context: nil)
            let th = min(bound.height, titleRect.height - 24)
            ns.draw(with: CGRect(x: titleRect.minX, y: titleRect.minY + (titleRect.height - 24 - th) / 2, width: titleRect.width, height: th),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttrs, context: nil)
            if !author.isEmpty {
                let aFont = L10n.isJa ? (UIFont(name: "HiraMinProN-W3", size: 11) ?? UIFont.systemFont(ofSize: 11))
                                      : FontChoice.serif.uiFont(size: 11)
                let aAttrs: [NSAttributedString.Key: Any] = [.font: aFont, .paragraphStyle: para,
                                                             .foregroundColor: UIColor(red: 0.40, green: 0.33, blue: 0.26, alpha: 1)]
                (author as NSString).draw(with: CGRect(x: titleRect.minX, y: label.maxY - 30, width: titleRect.width, height: 16),
                                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: aAttrs, context: nil)
            }
            // Gilt ornament near the bottom.
            let gilt = UIColor(red: 0.85, green: 0.70, blue: 0.40, alpha: 0.85)
            cg.setStrokeColor(gilt.cgColor)
            cg.setLineWidth(1.2)
            let oy = size.height * 0.80
            cg.move(to: CGPoint(x: size.width * 0.30, y: oy)); cg.addLine(to: CGPoint(x: size.width * 0.70, y: oy))
            cg.strokePath()
            cg.setFillColor(gilt.cgColor)
            let d: CGFloat = 5
            let c = CGPoint(x: size.width * 0.5, y: oy)
            cg.move(to: CGPoint(x: c.x, y: c.y - d)); cg.addLine(to: CGPoint(x: c.x + d, y: c.y))
            cg.addLine(to: CGPoint(x: c.x, y: c.y + d)); cg.addLine(to: CGPoint(x: c.x - d, y: c.y)); cg.closePath()
            cg.fillPath()
        }
    }
}
