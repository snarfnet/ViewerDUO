import SwiftUI

/// Deterministic pseudo-random numbers so textures are stable between redraws.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

/// The surface the book rests on: gradients plus a procedurally drawn material texture.
struct DeskBackground: View {
    let desk: DeskStyle

    var body: some View {
        ZStack {
            LinearGradient(colors: [desk.highlight, desk.base, desk.shadow], startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas(rendersAsynchronously: true) { ctx, size in
                draw(ctx: &ctx, size: size)
            }
            RadialGradient(colors: [.clear, desk.shadow.opacity(desk.isDark ? 0.55 : 0.28)], center: .center, startRadius: 380, endRadius: 1100)
        }
        .ignoresSafeArea()
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize) {
        var rng = SeededRandom(seed: 7)
        switch desk.kind {
        case .walnut:
            // Long wavy grain lines running horizontally.
            let count = Int(size.height / 9) + 8
            for i in 0..<count {
                var path = Path()
                let y0 = CGFloat(i) * 9 + CGFloat(rng.range(-4, 4))
                path.move(to: CGPoint(x: -20, y: y0))
                var x: CGFloat = -20
                var y = y0
                let amp = CGFloat(rng.range(2, 9))
                let freq = CGFloat(rng.range(0.004, 0.012))
                let phase = CGFloat(rng.range(0, 6.28))
                while x < size.width + 20 {
                    x += 24
                    y = y0 + sin(x * freq + phase) * amp + CGFloat(rng.range(-0.8, 0.8))
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                let w = CGFloat(rng.range(0.4, 1.6))
                ctx.stroke(path, with: .color(desk.grain.opacity(rng.range(0.10, 0.28))), lineWidth: w)
            }
            // A few darker knots.
            for _ in 0..<3 {
                let c = CGPoint(x: CGFloat(rng.range(0.1, 0.9)) * size.width, y: CGFloat(rng.range(0.1, 0.9)) * size.height)
                for k in 0..<5 {
                    let r = CGFloat(18 + k * 9)
                    let rect = CGRect(x: c.x - r * 1.8, y: c.y - r * 0.55, width: r * 3.6, height: r * 1.1)
                    ctx.stroke(Path(ellipseIn: rect), with: .color(desk.grain.opacity(0.18)), lineWidth: 0.8)
                }
            }
        case .marble:
            for _ in 0..<9 {
                var path = Path()
                var p = CGPoint(x: CGFloat(rng.range(-0.1, 1.1)) * size.width, y: -10)
                path.move(to: p)
                while p.y < size.height + 10 {
                    let n = CGPoint(x: p.x + CGFloat(rng.range(-70, 70)), y: p.y + CGFloat(rng.range(40, 120)))
                    let c1 = CGPoint(x: p.x + CGFloat(rng.range(-50, 50)), y: p.y + 30)
                    let c2 = CGPoint(x: n.x + CGFloat(rng.range(-50, 50)), y: n.y - 30)
                    path.addCurve(to: n, control1: c1, control2: c2)
                    p = n
                }
                ctx.stroke(path, with: .color(desk.grain.opacity(rng.range(0.08, 0.22))), lineWidth: CGFloat(rng.range(0.5, 2.2)))
            }
            for _ in 0..<40 {
                let r = CGFloat(rng.range(30, 160))
                let rect = CGRect(x: CGFloat(rng.range(0, 1)) * size.width - r / 2, y: CGFloat(rng.range(0, 1)) * size.height - r / 2, width: r, height: r * 0.6)
                ctx.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(rng.range(0.03, 0.09))))
            }
        case .linen:
            var path = Path()
            var x: CGFloat = 0
            while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += 3 }
            var y: CGFloat = 0
            while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += 3 }
            ctx.stroke(path, with: .color(desk.grain.opacity(0.16)), lineWidth: 0.6)
            for _ in 0..<120 {
                let rect = CGRect(x: CGFloat(rng.range(0, 1)) * size.width, y: CGFloat(rng.range(0, 1)) * size.height, width: CGFloat(rng.range(6, 40)), height: 1)
                ctx.fill(Path(rect), with: .color(desk.highlight.opacity(rng.range(0.10, 0.30))))
            }
        case .leather:
            for _ in 0..<700 {
                let r = CGFloat(rng.range(1.2, 4.5))
                let rect = CGRect(x: CGFloat(rng.range(0, 1)) * size.width, y: CGFloat(rng.range(0, 1)) * size.height, width: r, height: r * CGFloat(rng.range(0.6, 1.4)))
                let dark = rng.next() > 0.5
                ctx.fill(Path(ellipseIn: rect), with: .color((dark ? desk.shadow : desk.highlight).opacity(rng.range(0.10, 0.35))))
            }
            // Stitched border.
            let inset: CGFloat = 26
            let rect = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
            let stitch = Path(roundedRect: rect, cornerRadius: 18)
            ctx.stroke(stitch, with: .color(desk.accent.opacity(0.45)), style: StrokeStyle(lineWidth: 1.4, dash: [7, 6]))
        case .slate:
            for _ in 0..<500 {
                let r = CGFloat(rng.range(0.6, 2.2))
                let rect = CGRect(x: CGFloat(rng.range(0, 1)) * size.width, y: CGFloat(rng.range(0, 1)) * size.height, width: r, height: r)
                ctx.fill(Path(ellipseIn: rect), with: .color(desk.grain.opacity(rng.range(0.15, 0.45))))
            }
        case .ivory:
            for _ in 0..<60 {
                let r = CGFloat(rng.range(60, 260))
                let rect = CGRect(x: CGFloat(rng.range(0, 1)) * size.width - r / 2, y: CGFloat(rng.range(0, 1)) * size.height - r / 2, width: r, height: r)
                ctx.fill(Path(ellipseIn: rect), with: .color(desk.grain.opacity(rng.range(0.03, 0.08))))
            }
        }
    }
}

// MARK: - Chrome components

struct ChromeButton: View {
    let desk: DeskStyle
    let systemName: String
    var size: CGFloat = 40
    var active = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(active ? desk.accent : desk.ink.opacity(disabled ? 0.35 : 0.92))
                .frame(width: size, height: size)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().stroke(desk.ink.opacity(0.12), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct ChromeBar<Content: View>: View {
    let desk: DeskStyle
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(desk.ink.opacity(0.12), lineWidth: 0.6))
            .shadow(color: .black.opacity(desk.isDark ? 0.35 : 0.15), radius: 12, y: 4)
    }
}

/// Small swatch used by pickers for desks and papers.
struct Swatch: View {
    let colors: [Color]
    let label: String
    let selected: Bool
    let accent: Color
    let ink: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 48, height: 48)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected ? accent : ink.opacity(0.15), lineWidth: selected ? 2.5 : 0.8))
                Text(label)
                    .font(DuoFont.caption(11))
                    .foregroundStyle(ink.opacity(selected ? 1 : 0.7))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}
