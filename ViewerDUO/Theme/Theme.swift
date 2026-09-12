import SwiftUI
import UIKit

// MARK: - Desk (the surface behind the book)

struct DeskStyle: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case walnut, marble, linen, leather, slate, ivory }
    let kind: Kind
    var id: String { kind.rawValue }
    let nameJa: String
    let nameEn: String
    let base: Color
    let highlight: Color
    let shadow: Color
    let grain: Color
    let isDark: Bool
    /// Brass accent used for controls on this desk.
    let accent: Color
    /// Foreground colour for chrome text on this desk.
    let ink: Color

    var name: String { L10n.isJa ? nameJa : nameEn }

    static let all: [DeskStyle] = [
        DeskStyle(kind: .walnut, nameJa: "胡桃", nameEn: "Walnut",
                  base: Color(red: 0.24, green: 0.15, blue: 0.10), highlight: Color(red: 0.36, green: 0.23, blue: 0.14),
                  shadow: Color(red: 0.10, green: 0.06, blue: 0.04), grain: Color(red: 0.16, green: 0.09, blue: 0.05),
                  isDark: true, accent: Color(red: 0.85, green: 0.69, blue: 0.38), ink: Color(red: 0.95, green: 0.90, blue: 0.80)),
        DeskStyle(kind: .marble, nameJa: "大理石", nameEn: "Marble",
                  base: Color(red: 0.88, green: 0.87, blue: 0.85), highlight: Color(red: 0.96, green: 0.95, blue: 0.93),
                  shadow: Color(red: 0.72, green: 0.71, blue: 0.70), grain: Color(red: 0.60, green: 0.60, blue: 0.62),
                  isDark: false, accent: Color(red: 0.62, green: 0.48, blue: 0.22), ink: Color(red: 0.18, green: 0.17, blue: 0.16)),
        DeskStyle(kind: .linen, nameJa: "藍リネン", nameEn: "Indigo linen",
                  base: Color(red: 0.13, green: 0.17, blue: 0.26), highlight: Color(red: 0.20, green: 0.25, blue: 0.36),
                  shadow: Color(red: 0.06, green: 0.08, blue: 0.14), grain: Color(red: 0.24, green: 0.29, blue: 0.40),
                  isDark: true, accent: Color(red: 0.86, green: 0.74, blue: 0.48), ink: Color(red: 0.90, green: 0.92, blue: 0.96)),
        DeskStyle(kind: .leather, nameJa: "革", nameEn: "Leather",
                  base: Color(red: 0.33, green: 0.11, blue: 0.10), highlight: Color(red: 0.46, green: 0.17, blue: 0.14),
                  shadow: Color(red: 0.14, green: 0.04, blue: 0.04), grain: Color(red: 0.22, green: 0.07, blue: 0.06),
                  isDark: true, accent: Color(red: 0.90, green: 0.75, blue: 0.45), ink: Color(red: 0.96, green: 0.90, blue: 0.84)),
        DeskStyle(kind: .slate, nameJa: "黒曜", nameEn: "Obsidian",
                  base: Color(red: 0.09, green: 0.09, blue: 0.10), highlight: Color(red: 0.16, green: 0.16, blue: 0.18),
                  shadow: Color(red: 0.02, green: 0.02, blue: 0.02), grain: Color(red: 0.20, green: 0.20, blue: 0.22),
                  isDark: true, accent: Color(red: 0.80, green: 0.70, blue: 0.50), ink: Color(red: 0.90, green: 0.90, blue: 0.90)),
        DeskStyle(kind: .ivory, nameJa: "象牙", nameEn: "Ivory",
                  base: Color(red: 0.93, green: 0.90, blue: 0.83), highlight: Color(red: 0.98, green: 0.97, blue: 0.93),
                  shadow: Color(red: 0.80, green: 0.76, blue: 0.68), grain: Color(red: 0.84, green: 0.80, blue: 0.72),
                  isDark: false, accent: Color(red: 0.55, green: 0.40, blue: 0.18), ink: Color(red: 0.22, green: 0.18, blue: 0.14)),
    ]

    static func named(_ id: String) -> DeskStyle { all.first { $0.id == id } ?? all[0] }
}

// MARK: - Paper (the page surface)

struct PaperStyle: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case white, cream, parchment, sepia, moss, night }
    let kind: Kind
    var id: String { kind.rawValue }
    let nameJa: String
    let nameEn: String
    let background: UIColor
    let text: UIColor
    let heading: UIColor
    let muted: UIColor
    let isDark: Bool
    /// Vignette strength applied when rendering text pages (0 = flat colour).
    let vignette: CGFloat

    var name: String { L10n.isJa ? nameJa : nameEn }
    var color: Color { Color(background) }

    static let all: [PaperStyle] = [
        PaperStyle(kind: .white, nameJa: "純白", nameEn: "White",
                   background: UIColor(red: 0.99, green: 0.99, blue: 0.985, alpha: 1), text: UIColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1),
                   heading: UIColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1), muted: UIColor(red: 0.55, green: 0.55, blue: 0.56, alpha: 1),
                   isDark: false, vignette: 0.0),
        PaperStyle(kind: .cream, nameJa: "クリーム", nameEn: "Cream",
                   background: UIColor(red: 0.98, green: 0.955, blue: 0.90, alpha: 1), text: UIColor(red: 0.17, green: 0.14, blue: 0.11, alpha: 1),
                   heading: UIColor(red: 0.12, green: 0.09, blue: 0.06, alpha: 1), muted: UIColor(red: 0.58, green: 0.53, blue: 0.46, alpha: 1),
                   isDark: false, vignette: 0.04),
        PaperStyle(kind: .parchment, nameJa: "羊皮紙", nameEn: "Parchment",
                   background: UIColor(red: 0.92, green: 0.86, blue: 0.72, alpha: 1), text: UIColor(red: 0.22, green: 0.15, blue: 0.09, alpha: 1),
                   heading: UIColor(red: 0.30, green: 0.16, blue: 0.08, alpha: 1), muted: UIColor(red: 0.55, green: 0.45, blue: 0.33, alpha: 1),
                   isDark: false, vignette: 0.16),
        PaperStyle(kind: .sepia, nameJa: "セピア", nameEn: "Sepia",
                   background: UIColor(red: 0.95, green: 0.90, blue: 0.80, alpha: 1), text: UIColor(red: 0.32, green: 0.22, blue: 0.13, alpha: 1),
                   heading: UIColor(red: 0.26, green: 0.16, blue: 0.08, alpha: 1), muted: UIColor(red: 0.62, green: 0.52, blue: 0.40, alpha: 1),
                   isDark: false, vignette: 0.08),
        PaperStyle(kind: .moss, nameJa: "若草", nameEn: "Moss",
                   background: UIColor(red: 0.85, green: 0.90, blue: 0.80, alpha: 1), text: UIColor(red: 0.14, green: 0.18, blue: 0.12, alpha: 1),
                   heading: UIColor(red: 0.10, green: 0.14, blue: 0.08, alpha: 1), muted: UIColor(red: 0.45, green: 0.52, blue: 0.40, alpha: 1),
                   isDark: false, vignette: 0.03),
        PaperStyle(kind: .night, nameJa: "夜間", nameEn: "Night",
                   background: UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1), text: UIColor(red: 0.80, green: 0.78, blue: 0.74, alpha: 1),
                   heading: UIColor(red: 0.92, green: 0.88, blue: 0.80, alpha: 1), muted: UIColor(red: 0.50, green: 0.49, blue: 0.47, alpha: 1),
                   isDark: true, vignette: 0.0),
    ]

    static func named(_ id: String) -> PaperStyle { all.first { $0.id == id } ?? all[1] }
}

// MARK: - Typeface

enum FontChoice: String, CaseIterable, Identifiable {
    case mincho, gothic, serif, sans, rounded
    var id: String { rawValue }

    var name: String {
        switch self {
        case .mincho: return L10n.t("明朝", "Mincho")
        case .gothic: return L10n.t("ゴシック", "Gothic")
        case .serif: return L10n.t("セリフ", "Serif")
        case .sans: return L10n.t("サンセリフ", "Sans")
        case .rounded: return L10n.t("丸ゴシック", "Rounded")
        }
    }

    func uiFont(size: CGFloat, bold: Bool = false) -> UIFont {
        switch self {
        case .mincho:
            return UIFont(name: bold ? "HiraMinProN-W6" : "HiraMinProN-W3", size: size)
                ?? UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        case .gothic:
            return UIFont(name: bold ? "HiraginoSans-W6" : "HiraginoSans-W3", size: size)
                ?? UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        case .serif:
            return Self.system(size: size, bold: bold, design: .serif)
        case .sans:
            return Self.system(size: size, bold: bold, design: .default)
        case .rounded:
            return Self.system(size: size, bold: bold, design: .rounded)
        }
    }

    private static func system(size: CGFloat, bold: Bool, design: UIFontDescriptor.SystemDesign) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        if let d = base.fontDescriptor.withDesign(design) {
            return UIFont(descriptor: d, size: size)
        }
        return base
    }

    var swiftUIFont: Font {
        switch self {
        case .mincho: return .custom("HiraMinProN-W3", size: 15)
        case .gothic: return .custom("HiraginoSans-W3", size: 15)
        case .serif: return .system(size: 15, design: .serif)
        case .sans: return .system(size: 15)
        case .rounded: return .system(size: 15, design: .rounded)
        }
    }
}

// MARK: - Chrome fonts

enum DuoFont {
    static func title(_ size: CGFloat) -> Font {
        L10n.isJa ? .custom("HiraMinProN-W6", size: size) : .system(size: size, weight: .semibold, design: .serif)
    }
    static func body(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .rounded)
    }
    static func caption(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .rounded)
    }
}
