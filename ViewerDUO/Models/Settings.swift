import SwiftUI
import UIKit

enum LayoutMode: String, CaseIterable, Identifiable {
    case auto, single, spread
    var id: String { rawValue }
    var name: String {
        switch self {
        case .auto: return L10n.layoutAuto
        case .single: return L10n.layoutSingle
        case .spread: return L10n.layoutSpread
        }
    }
    var symbol: String {
        switch self {
        case .auto: return "rectangle.on.rectangle.angled"
        case .single: return "doc"
        case .spread: return "book"
        }
    }
}

final class DuoSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var deskID: String { didSet { d.set(deskID, forKey: "deskID") } }
    @Published var paperID: String { didSet { d.set(paperID, forKey: "paperID") } }
    @Published var fontID: String { didSet { d.set(fontID, forKey: "fontID") } }
    @Published var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize") } }
    @Published var lineSpacing: Double { didSet { d.set(lineSpacing, forKey: "lineSpacing") } }
    @Published var margin: Double { didSet { d.set(margin, forKey: "margin") } }
    @Published var layoutMode: LayoutMode { didSet { d.set(layoutMode.rawValue, forKey: "layoutMode") } }
    @Published var rightToLeft: Bool { didSet { d.set(rightToLeft, forKey: "rightToLeft") } }
    @Published var verticalText: Bool { didSet { d.set(verticalText, forKey: "verticalText") } }
    @Published var warmth: Double { didSet { d.set(warmth, forKey: "warmth") } }
    @Published var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
    @Published var keepAwake: Bool { didSet { d.set(keepAwake, forKey: "keepAwake") } }
    @Published var coverAlone: Bool { didSet { d.set(coverAlone, forKey: "coverAlone") } }
    @Published var pageStack: Bool { didSet { d.set(pageStack, forKey: "pageStack") } }
    @Published var curlSoftness: Double { didSet { d.set(curlSoftness, forKey: "curlSoftness") } }
    /// "curl" turns paper; "slide" shows two pages side by side and swipes both at once.
    @Published var turnStyle: String { didSet { d.set(turnStyle, forKey: "turnStyle") } }
    @Published var sortOrder: String { didSet { d.set(sortOrder, forKey: "sortOrder") } }

    init() {
        deskID = d.string(forKey: "deskID") ?? "walnut"
        paperID = d.string(forKey: "paperID") ?? "cream"
        fontID = d.string(forKey: "fontID") ?? (L10n.isJa ? "mincho" : "serif")
        let fs = d.double(forKey: "fontSize")
        fontSize = fs > 0 ? fs : 17
        let ls = d.double(forKey: "lineSpacing")
        lineSpacing = ls > 0 ? ls : 1.7
        let mg = d.double(forKey: "margin")
        margin = mg > 0 ? mg : 1.0
        layoutMode = LayoutMode(rawValue: d.string(forKey: "layoutMode") ?? "") ?? .auto
        rightToLeft = d.bool(forKey: "rightToLeft")
        verticalText = d.bool(forKey: "verticalText")
        warmth = d.object(forKey: "warmth") == nil ? 0 : d.double(forKey: "warmth")
        haptics = d.object(forKey: "haptics") == nil ? true : d.bool(forKey: "haptics")
        keepAwake = d.object(forKey: "keepAwake") == nil ? true : d.bool(forKey: "keepAwake")
        coverAlone = d.object(forKey: "coverAlone") == nil ? true : d.bool(forKey: "coverAlone")
        pageStack = d.object(forKey: "pageStack") == nil ? true : d.bool(forKey: "pageStack")
        curlSoftness = d.object(forKey: "curlSoftness") == nil ? 0.5 : d.double(forKey: "curlSoftness")
        sortOrder = d.string(forKey: "sortOrder") ?? "recent"
        turnStyle = d.string(forKey: "turnStyle") ?? "curl"
        if ScreenshotMode.isActive {
            deskID = "walnut"
            paperID = "cream"
            warmth = 0
            turnStyle = ScreenshotMode.target == "slide" ? "slide" : "curl"
            coverAlone = ScreenshotMode.target != "slide"
        }
    }

    var desk: DeskStyle { DeskStyle.named(deskID) }
    var paper: PaperStyle { PaperStyle.named(paperID) }
    var font: FontChoice { FontChoice(rawValue: fontID) ?? .serif }

    /// Snapshot of everything that affects how a text page is rendered.
    var textStyle: TextStyle {
        TextStyle(paper: paper, font: font, fontSize: CGFloat(fontSize), lineSpacing: CGFloat(lineSpacing),
                  margin: CGFloat(margin), vertical: verticalText)
    }

    func tap() {
        guard haptics else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    func pageTurned() {
        guard haptics else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
    }

    func thud() {
        guard haptics else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }
}

/// Everything the text renderer needs to lay out and draw a page.
struct TextStyle: Equatable {
    var paper: PaperStyle
    var font: FontChoice
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var margin: CGFloat
    var vertical: Bool
    var title: String = ""

    static func == (a: TextStyle, b: TextStyle) -> Bool {
        a.paper.id == b.paper.id && a.font == b.font && a.fontSize == b.fontSize && a.lineSpacing == b.lineSpacing
            && a.margin == b.margin && a.vertical == b.vertical && a.title == b.title
    }
}
