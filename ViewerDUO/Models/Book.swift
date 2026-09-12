import Foundation

enum BookFormat: String, Codable, CaseIterable {
    case pdf, epub, txt, zip, rar

    static func from(ext: String) -> BookFormat? {
        switch ext.lowercased() {
        case "pdf": return .pdf
        case "epub": return .epub
        case "txt", "text", "md": return .txt
        case "zip", "cbz": return .zip
        case "rar", "cbr": return .rar
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .epub: return "EPUB"
        case .txt: return "TEXT"
        case .zip: return "ZIP"
        case .rar: return "RAR"
        }
    }

    var isImageArchive: Bool { self == .zip || self == .rar }
    /// Text-based formats are re-paginated whenever the page size or typography changes.
    var isReflowable: Bool { self == .txt || self == .epub }
}

struct Bookmark: Codable, Identifiable, Hashable {
    var id: UUID
    var page: Int
    /// Character offset for reflowable books so the bookmark survives re-pagination.
    var offset: Int
    var label: String
    var createdAt: Date
}

struct Book: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var title: String
    var author: String
    var fileName: String
    var format: BookFormat
    var addedAt: Date
    var lastOpened: Date?
    var lastPage: Int
    var lastOffset: Int
    var pageCount: Int
    var bookmarks: [Bookmark]
    /// Per-book overrides; nil means "follow the global setting".
    var rightToLeft: Bool?
    var verticalText: Bool?
    var hue: Double

    init(id: UUID, title: String, author: String = "", fileName: String, format: BookFormat, addedAt: Date,
         lastOpened: Date? = nil, lastPage: Int = 0, lastOffset: Int = 0, pageCount: Int = 0,
         bookmarks: [Bookmark] = [], rightToLeft: Bool? = nil, verticalText: Bool? = nil, hue: Double? = nil) {
        self.id = id
        self.title = title
        self.author = author
        self.fileName = fileName
        self.format = format
        self.addedAt = addedAt
        self.lastOpened = lastOpened
        self.lastPage = lastPage
        self.lastOffset = lastOffset
        self.pageCount = pageCount
        self.bookmarks = bookmarks
        self.rightToLeft = rightToLeft
        self.verticalText = verticalText
        self.hue = hue ?? Double(id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360) / 360.0
    }

    enum CodingKeys: String, CodingKey {
        case id, title, author, fileName, format, addedAt, lastOpened, lastPage, lastOffset, pageCount, bookmarks, rightToLeft, verticalText, hue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        self.init(id: id,
                  title: try c.decode(String.self, forKey: .title),
                  author: try c.decodeIfPresent(String.self, forKey: .author) ?? "",
                  fileName: try c.decode(String.self, forKey: .fileName),
                  format: try c.decode(BookFormat.self, forKey: .format),
                  addedAt: try c.decode(Date.self, forKey: .addedAt),
                  lastOpened: try c.decodeIfPresent(Date.self, forKey: .lastOpened),
                  lastPage: try c.decodeIfPresent(Int.self, forKey: .lastPage) ?? 0,
                  lastOffset: try c.decodeIfPresent(Int.self, forKey: .lastOffset) ?? 0,
                  pageCount: try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0,
                  bookmarks: try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? [],
                  rightToLeft: try c.decodeIfPresent(Bool.self, forKey: .rightToLeft),
                  verticalText: try c.decodeIfPresent(Bool.self, forKey: .verticalText),
                  hue: try c.decodeIfPresent(Double.self, forKey: .hue))
    }

    var progress: Double {
        guard pageCount > 1 else { return 0 }
        return min(1, max(0, Double(lastPage) / Double(pageCount - 1)))
    }
}

struct Chapter: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let page: Int
    let depth: Int

    init(title: String, page: Int, depth: Int = 0) {
        self.title = title
        self.page = page
        self.depth = depth
    }
}

struct SearchHit: Identifiable {
    let id = UUID()
    let page: Int
    let snippet: String
}
