import Foundation

/// Minimal ZIP reader (stored + deflate) with no third-party dependency.
struct MiniZipEntry {
    let name: String
    let method: Int
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
    var isDirectory: Bool { name.hasSuffix("/") }
}

enum MiniZipError: Error {
    case notAZip
    case corrupt
    case unsupportedMethod(Int)
}

struct MiniZip {
    let data: Data
    private(set) var entries: [MiniZipEntry] = []

    init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        self.data = data
        try parseCentralDirectory()
    }

    private func byte(_ o: Int) -> Int { Int(data[data.startIndex + o]) }
    private func u16(_ o: Int) -> Int { byte(o) | (byte(o + 1) << 8) }
    private func u32(_ o: Int) -> Int { u16(o) | (u16(o + 2) << 16) }

    private mutating func parseCentralDirectory() throws {
        let n = data.count
        guard n >= 22 else { throw MiniZipError.notAZip }
        var eocd = -1
        var p = n - 22
        let limit = max(0, n - 22 - 65_536)
        while p >= limit {
            if u32(p) == 0x06054b50 { eocd = p; break }
            p -= 1
        }
        guard eocd >= 0 else { throw MiniZipError.notAZip }
        let count = u16(eocd + 10)
        let cdOffset = u32(eocd + 16)
        var q = cdOffset
        var list: [MiniZipEntry] = []
        for _ in 0..<count {
            guard q + 46 <= n, u32(q) == 0x02014b50 else { throw MiniZipError.corrupt }
            let method = u16(q + 10)
            let comp = u32(q + 20)
            let uncomp = u32(q + 24)
            let nameLen = u16(q + 28)
            let extraLen = u16(q + 30)
            let commentLen = u16(q + 32)
            let local = u32(q + 42)
            let nameStart = data.startIndex + q + 46
            let nameData = data[nameStart..<(nameStart + nameLen)]
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .shiftJIS)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? "entry_\(list.count)"
            list.append(MiniZipEntry(name: name, method: method, compressedSize: comp,
                                     uncompressedSize: uncomp, localHeaderOffset: local))
            q += 46 + nameLen + extraLen + commentLen
        }
        entries = list
    }

    func extract(_ entry: MiniZipEntry) throws -> Data {
        let lho = entry.localHeaderOffset
        guard lho + 30 <= data.count, u32(lho) == 0x04034b50 else { throw MiniZipError.corrupt }
        let nameLen = u16(lho + 26)
        let extraLen = u16(lho + 28)
        let start = lho + 30 + nameLen + extraLen
        guard start + entry.compressedSize <= data.count else { throw MiniZipError.corrupt }
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        switch entry.method {
        case 0:
            return raw
        case 8:
            do {
                return try (raw as NSData).decompressed(using: .zlib) as Data
            } catch {
                throw MiniZipError.corrupt
            }
        default:
            throw MiniZipError.unsupportedMethod(entry.method)
        }
    }
}
