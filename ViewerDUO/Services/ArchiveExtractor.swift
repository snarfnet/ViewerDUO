import Foundation
import Unrar

enum ArchiveError: Error {
    case noImages
    case cannotOpen
}

/// Extracts ZIP/CBZ/RAR/CBR image archives into the cache and returns image page URLs in natural order.
enum ArchiveExtractor {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "tif", "tiff"]

    static func imagePages(fileURL: URL, format: BookFormat, bookID: UUID) throws -> [URL] {
        let dir = Library.cacheDir(for: bookID)
        let marker = dir.appendingPathComponent(".extracted")
        if !FileManager.default.fileExists(atPath: marker.path) {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            switch format {
            case .zip: try extractZip(fileURL, to: dir)
            case .rar: try extractRar(fileURL, to: dir)
            default: throw ArchiveError.cannotOpen
            }
            try Data().write(to: marker)
        }
        let pages = listImages(in: dir)
        if pages.isEmpty { throw ArchiveError.noImages }
        return pages
    }

    static func safeRelativePath(_ name: String) -> String? {
        let parts = name.split(separator: "/").map(String.init)
        if parts.isEmpty || parts.contains("..") || parts.contains(where: { $0.hasPrefix("__MACOSX") }) { return nil }
        if parts.last?.hasPrefix(".") == true { return nil }
        return parts.joined(separator: "/")
    }

    private static func extractZip(_ url: URL, to dir: URL) throws {
        let zip = try MiniZip(url: url)
        for e in zip.entries where !e.isDirectory {
            let name = e.name.replacingOccurrences(of: "\\", with: "/")
            guard let rel = safeRelativePath(name) else { continue }
            let ext = (rel as NSString).pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            let out = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? zip.extract(e) { try d.write(to: out) }
        }
    }

    private static func extractRar(_ url: URL, to dir: URL) throws {
        let archive = try Archive(fileURL: url)
        let entries = try archive.entries()
        for e in entries where !e.directory {
            let name = e.fileName.replacingOccurrences(of: "\\", with: "/")
            guard let rel = safeRelativePath(name) else { continue }
            let ext = (rel as NSString).pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            let out = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? archive.extract(e) { try d.write(to: out) }
        }
    }

    static func listImages(in dir: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var urls: [URL] = []
        for case let u as URL in en {
            if imageExtensions.contains(u.pathExtension.lowercased()) { urls.append(u) }
        }
        let base = dir.path
        return urls.sorted { a, b in
            let ra = String(a.path.dropFirst(base.count))
            let rb = String(b.path.dropFirst(base.count))
            return ra.localizedStandardCompare(rb) == .orderedAscending
        }
    }
}
