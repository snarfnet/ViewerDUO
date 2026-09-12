import Foundation
import UIKit

/// Semantic attributes carried by a chapter's text before typography is applied.
extension NSAttributedString.Key {
    static let duoBold = NSAttributedString.Key("duo.bold")
    static let duoItalic = NSAttributedString.Key("duo.italic")
    static let duoHeading = NSAttributedString.Key("duo.heading")   // Int 1...6
    static let duoCenter = NSAttributedString.Key("duo.center")
    static let duoQuote = NSAttributedString.Key("duo.quote")
    static let duoImage = NSAttributedString.Key("duo.image")       // URL
    static let duoPre = NSAttributedString.Key("duo.pre")
}

struct ChapterText {
    var title: String
    var rich: NSAttributedString
    var plain: String { rich.string }
}

enum RichText {
    static let objectReplacement = "\u{FFFC}"

    // MARK: Plain text (TXT)

    private static let headingPatterns: [NSRegularExpression] = {
        let pats = [
            "^(第[0-9０-９〇一二三四五六七八九十百千]+[章話部節幕巻編])(\\s|$|[　：:].*$)",
            "^(序章|終章|序|跋|前書き|あとがき|プロローグ|エピローグ|序幕|終幕)(\\s|$|[　：:].*$)",
            "^(CHAPTER|Chapter|PART|Part|BOOK|Book)\\s+([0-9]+|[IVXLC]+|[A-Za-z]+)\\b.*$",
            "^(PROLOGUE|Prologue|EPILOGUE|Epilogue|PREFACE|Preface|INTRODUCTION|Introduction|AFTERWORD|Afterword)\\s*$",
            "^([0-9]{1,3})\\.?\\s+[A-Z][A-Za-z ,'’-]{2,60}$",
        ]
        return pats.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    static func isHeading(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 60 else { return false }
        let r = NSRange(t.startIndex..., in: t)
        return headingPatterns.contains { $0.firstMatch(in: t, options: [], range: r) != nil }
    }

    /// Cleans Aozora-Bunko style annotations: ｜漢字《かんじ》 ruby and ［＃…］ typesetting notes.
    static func cleanPlain(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if s.contains("《") {
            s = s.replacingOccurrences(of: "《[^》]{0,40}》", with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: "｜", with: "")
        }
        if s.contains("［＃") {
            s = s.replacingOccurrences(of: "［＃[^］]{0,80}］", with: "", options: .regularExpression)
        }
        return s
    }

    static func fromPlainText(_ raw: String, fallbackTitle: String) -> [ChapterText] {
        let text = cleanPlain(raw)
        let lines = text.components(separatedBy: "\n")
        let headingIdx = lines.indices.filter { isHeading(lines[$0]) }
        var chapters: [ChapterText] = []

        func build(_ slice: ArraySlice<String>, title: String, headingLine: String?) -> ChapterText {
            let out = NSMutableAttributedString()
            if let h = headingLine {
                out.append(NSAttributedString(string: h.trimmingCharacters(in: .whitespaces) + "\n",
                                              attributes: [.duoHeading: 2, .duoBold: true]))
            }
            var blank = 0
            for line in slice {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    blank += 1
                    if blank == 1 { out.append(NSAttributedString(string: "\n")) }
                    continue
                }
                blank = 0
                out.append(NSAttributedString(string: line + "\n"))
            }
            return ChapterText(title: title, rich: out)
        }

        if headingIdx.count >= 2 {
            if headingIdx[0] > 0 {
                let pre = lines[0..<headingIdx[0]]
                if pre.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    chapters.append(build(pre, title: fallbackTitle, headingLine: nil))
                }
            }
            for (k, h) in headingIdx.enumerated() {
                let end = k + 1 < headingIdx.count ? headingIdx[k + 1] : lines.count
                let body = lines[(h + 1)..<end]
                chapters.append(build(body, title: lines[h].trimmingCharacters(in: .whitespaces), headingLine: lines[h]))
            }
        } else {
            chapters.append(build(lines[...], title: fallbackTitle, headingLine: nil))
        }
        return chapters
    }

    // MARK: XHTML (EPUB)

    private static let namedEntities: [String: String] = [
        "&nbsp;": "\u{00A0}", "&ensp;": "\u{2002}", "&emsp;": "\u{2003}", "&thinsp;": "\u{2009}",
        "&copy;": "©", "&reg;": "®", "&trade;": "™", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
        "&ldquo;": "“", "&rdquo;": "”", "&lsquo;": "‘", "&rsquo;": "’", "&laquo;": "«", "&raquo;": "»",
        "&bull;": "•", "&middot;": "·", "&deg;": "°", "&times;": "×", "&divide;": "÷", "&euro;": "€",
        "&pound;": "£", "&yen;": "¥", "&sect;": "§", "&para;": "¶", "&dagger;": "†", "&Dagger;": "‡",
        "&iexcl;": "¡", "&iquest;": "¿", "&shy;": "", "&zwj;": "\u{200D}", "&zwnj;": "\u{200C}",
        "&eacute;": "é", "&egrave;": "è", "&agrave;": "à", "&aacute;": "á", "&ouml;": "ö", "&uuml;": "ü",
        "&auml;": "ä", "&ccedil;": "ç", "&ntilde;": "ñ", "&oacute;": "ó", "&iacute;": "í", "&uacute;": "ú",
    ]

    private static let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol", "blockquote", "pre", "table", "tr",
        "section", "article", "aside", "header", "footer", "nav", "figure", "figcaption", "hr", "dt", "dd", "dl",
        "address", "body", "main", "center",
    ]
    private static let skipTags: Set<String> = ["head", "script", "style", "rt", "rp", "title", "svg", "math"]

    static func fromXHTML(url: URL, title: String) -> ChapterText {
        let data = (try? Data(contentsOf: url)) ?? Data()
        guard var raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS) else {
            return ChapterText(title: title, rich: NSAttributedString(string: ""))
        }
        raw = raw.replacingOccurrences(of: "<!DOCTYPE[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        for (k, v) in namedEntities where raw.contains(k) {
            raw = raw.replacingOccurrences(of: k, with: v)
        }
        let out = NSMutableAttributedString()
        if let data = raw.data(using: .utf8), let root = DVXMLTreeParser.parse(data) {
            let body = root.first("body") ?? root
            var ctx = WalkContext(baseURL: url.deletingLastPathComponent())
            walk(body, into: out, ctx: &ctx)
        } else {
            // Malformed XHTML: strip tags and keep paragraphs.
            let stripped = raw
                .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "</(p|div|h[1-6]|li|tr)>", with: "\n", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
            for line in stripped.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(NSAttributedString(string: t + "\n")) }
            }
        }
        trimTrailingNewlines(out)
        return ChapterText(title: title, rich: out)
    }

    private struct WalkContext {
        var baseURL: URL
        var bold = 0
        var italic = 0
        var heading = 0
        var center = 0
        var quote = 0
        var pre = 0
        var pendingSpace = false
    }

    private static func endsWithNewline(_ s: NSMutableAttributedString) -> Bool {
        s.length == 0 || s.string.hasSuffix("\n")
    }

    private static func attributes(_ ctx: WalkContext) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [:]
        if ctx.bold > 0 { a[.duoBold] = true }
        if ctx.italic > 0 { a[.duoItalic] = true }
        if ctx.heading > 0 { a[.duoHeading] = ctx.heading }
        if ctx.center > 0 { a[.duoCenter] = true }
        if ctx.quote > 0 { a[.duoQuote] = true }
        if ctx.pre > 0 { a[.duoPre] = true }
        return a
    }

    private static func appendText(_ text: String, into out: NSMutableAttributedString, ctx: inout WalkContext) {
        if ctx.pre > 0 {
            out.append(NSAttributedString(string: text, attributes: attributes(ctx)))
            return
        }
        var collapsed = ""
        var lastSpace = endsWithNewline(out) || ctx.pendingSpace
        for ch in text {
            if ch == " " || ch == "\n" || ch == "\t" || ch == "\r" {
                if !lastSpace { collapsed.append(" ") }
                lastSpace = true
            } else {
                collapsed.append(ch)
                lastSpace = false
            }
        }
        if endsWithNewline(out) { collapsed = String(collapsed.drop(while: { $0 == " " })) }
        guard !collapsed.isEmpty else { return }
        out.append(NSAttributedString(string: collapsed, attributes: attributes(ctx)))
        ctx.pendingSpace = false
    }

    private static func newline(_ out: NSMutableAttributedString, ctx: WalkContext) {
        // Remove a trailing space before closing the block.
        if out.string.hasSuffix(" ") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        if !endsWithNewline(out) { out.append(NSAttributedString(string: "\n", attributes: attributes(ctx))) }
    }

    private static func walk(_ node: DVXMLNode, into out: NSMutableAttributedString, ctx: inout WalkContext) {
        let name = node.name.lowercased()
        if skipTags.contains(name) { return }
        let isBlock = blockTags.contains(name)
        if isBlock { newline(out, ctx: ctx) }

        switch name {
        case "b", "strong": ctx.bold += 1
        case "i", "em", "cite": ctx.italic += 1
        case "h1", "h2", "h3", "h4", "h5", "h6":
            ctx.heading = Int(String(name.last!)) ?? 2
            ctx.bold += 1
        case "blockquote": ctx.quote += 1
        case "center": ctx.center += 1
        case "pre": ctx.pre += 1
        case "br":
            out.append(NSAttributedString(string: "\n", attributes: attributes(ctx)))
            return
        case "hr":
            out.append(NSAttributedString(string: "\u{2014}\u{2014}\u{2014}\n", attributes: [.duoCenter: true]))
            return
        case "img", "image":
            if let src = node.attr("src") ?? node.attr("href") {
                let cleaned = src.removingPercentEncoding ?? src
                let u = URL(fileURLWithPath: cleaned, relativeTo: ctx.baseURL).standardizedFileURL
                if FileManager.default.fileExists(atPath: u.path) {
                    newline(out, ctx: ctx)
                    out.append(NSAttributedString(string: objectReplacement + "\n", attributes: [.duoImage: u, .duoCenter: true]))
                }
            }
            return
        default: break
        }
        if let style = node.attr("style")?.lowercased(), style.contains("text-align") && style.contains("center") {
            ctx.center += 1
            defer { ctx.center -= 1 }
            appendChildren(node, into: out, ctx: &ctx)
        } else if let cls = node.attr("class")?.lowercased(), cls.contains("center") || cls == "title" {
            ctx.center += 1
            defer { ctx.center -= 1 }
            appendChildren(node, into: out, ctx: &ctx)
        } else {
            appendChildren(node, into: out, ctx: &ctx)
        }

        switch name {
        case "b", "strong": ctx.bold -= 1
        case "i", "em", "cite": ctx.italic -= 1
        case "h1", "h2", "h3", "h4", "h5", "h6":
            ctx.heading = 0
            ctx.bold -= 1
        case "blockquote": ctx.quote -= 1
        case "center": ctx.center -= 1
        case "pre": ctx.pre -= 1
        default: break
        }
        if isBlock { newline(out, ctx: ctx) }
    }

    private static func appendChildren(_ node: DVXMLNode, into out: NSMutableAttributedString, ctx: inout WalkContext) {
        // DVXMLNode stores text as one blob and children separately; interleave using the recorded order.
        for piece in node.pieces {
            switch piece {
            case .text(let t): appendText(t, into: out, ctx: &ctx)
            case .child(let c): walk(c, into: out, ctx: &ctx)
            }
        }
    }

    private static func trimTrailingNewlines(_ s: NSMutableAttributedString) {
        while s.length > 0, s.string.hasSuffix("\n\n") {
            s.deleteCharacters(in: NSRange(location: s.length - 1, length: 1))
        }
    }
}
