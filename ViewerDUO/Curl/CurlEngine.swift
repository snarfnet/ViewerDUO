import Foundation
import CoreGraphics
import QuartzCore

/// Geometry of the open book inside the view.
struct BookLayout: Equatable {
    var viewSize: CGSize = .zero
    var spread = false
    var rtl = false
    var pageSize: CGSize = CGSize(width: 100, height: 145)
    /// Screen x of the spine. In single mode this is the page edge that stays attached.
    var spineX: CGFloat = 0
    var top: CGFloat = 0

    var baseFlip: CGFloat { rtl ? -1 : 1 }
    /// Screen origin of leaf-local space: the spine at the top of the page.
    var origin: CGPoint { CGPoint(x: spineX, y: top) }

    static func make(viewSize: CGSize, spread: Bool, rtl: Bool, aspect: CGFloat, hingeX: CGFloat?, hingeGap: CGFloat) -> BookLayout {
        var l = BookLayout()
        l.viewSize = viewSize
        l.spread = spread
        l.rtl = rtl
        let margin: CGFloat = 14
        let availH = max(40, viewSize.height - margin * 2)
        if spread {
            let center = hingeX ?? viewSize.width / 2
            let halfLeft = center - margin - hingeGap / 2
            let halfRight = viewSize.width - center - margin - hingeGap / 2
            let availW = max(40, min(halfLeft, halfRight))
            let pw = min(availW, availH / aspect)
            l.pageSize = CGSize(width: pw, height: pw * aspect)
            l.spineX = center
            l.top = (viewSize.height - l.pageSize.height) / 2
        } else {
            let availW = max(40, viewSize.width - margin * 2)
            let pw = min(availW, availH / aspect)
            l.pageSize = CGSize(width: pw, height: pw * aspect)
            let left = (viewSize.width - pw) / 2
            l.spineX = rtl ? left + pw : left
            l.top = (viewSize.height - l.pageSize.height) / 2
        }
        return l
    }

    /// Converts a screen point into leaf-local coordinates for the given mirror state.
    func local(from screen: CGPoint, flip: CGFloat) -> CGPoint {
        CGPoint(x: (screen.x - spineX) * flip, y: screen.y - top)
    }
}

/// Which pages are shown where. Indices outside 0..<count are blank paper.
struct SpreadSlots {
    var first: Int      // page on the spine-left side in local space (spread only)
    var second: Int     // page on the local-right side (the leaf that turns forward)
}

/// The state machine behind page turning. Pure geometry; no UIKit.
final class CurlEngine {
    struct Turn {
        var direction: Int              // +1 forward, -1 backward
        var mirrored: Bool              // local space is mirrored relative to the layout
        var leaf: Int                   // page on the front of the moving leaf
        var back: Int?                  // page on the back of the leaf (nil = ghost/blank)
        var under: Int                  // page revealed beneath the leaf
        var stationary: Int?            // the other page in a spread
        var grab: CGPoint               // G: where the free edge was picked up (leaf-local)
        var finger: CGPoint             // F: current position of the grabbed point
        var start: CGPoint              // rest position where the turn began
        var target: CGPoint             // rest position that completes the turn
        var anim: Animation?
        var isAuto: Bool
    }

    struct Animation {
        var from: CGPoint
        var to: CGPoint
        var startTime: CFTimeInterval
        var duration: CFTimeInterval
        var arc: CGFloat
        var completes: Bool
    }

    var layout = BookLayout()
    var pageCount = 1
    var page = 0
    var coverAlone = true
    /// 0…1: larger values make a rounder, softer curl.
    var softness: CGFloat = 0.5
    private(set) var turn: Turn?

    var onPageChanged: ((Int) -> Void)?
    var onTurnCommitted: (() -> Void)?

    // MARK: - Page bookkeeping

    var slots: SpreadSlots { slots(forPage: page) }

    func slots(forPage page: Int) -> SpreadSlots {
        if !layout.spread { return SpreadSlots(first: page - 1, second: page) }
        let k = coverAlone ? (page + 1) / 2 : page / 2
        let first = coverAlone ? 2 * k - 1 : 2 * k
        return SpreadSlots(first: first, second: first + 1)
    }

    func isValid(_ index: Int) -> Bool { index >= 0 && index < pageCount }

    var canGoForward: Bool {
        layout.spread ? slots.second + 1 < pageCount : page + 1 < pageCount
    }

    var canGoBackward: Bool {
        layout.spread ? slots.first > 0 : page > 0
    }

    var isTurning: Bool { turn != nil }
    var isAnimating: Bool { turn?.anim != nil }

    /// Pages whose textures should be ready around the current position.
    var neededPages: [Int] {
        var set: [Int] = []
        let s = slots
        if layout.spread {
            set = [s.first, s.second, s.second + 1, s.second + 2, s.first - 1, s.first - 2, s.second + 3, s.second + 4]
        } else {
            set = [page, page + 1, page - 1, page + 2, page - 2, page + 3]
        }
        if let t = turn {
            set = [t.leaf, t.under, t.back ?? -1, t.stationary ?? -1] + set
        }
        var seen = Set<Int>()
        return set.filter { isValid($0) && seen.insert($0).inserted }
    }

    // MARK: - Starting a turn

    private var currentFlip: CGFloat {
        layout.baseFlip * ((turn?.mirrored ?? false) ? -1 : 1)
    }

    var flipX: CGFloat { currentFlip }

    /// Decides whether a touch at `screen` should start a turn, and in which direction.
    func directionForTouch(at screen: CGPoint) -> Int? {
        let p = layout.local(from: screen, flip: layout.baseFlip)
        let pw = layout.pageSize.width
        if layout.spread {
            if p.x >= 0 { return canGoForward ? 1 : nil }
            return canGoBackward ? -1 : nil
        }
        if p.x > pw * 0.5 { return canGoForward ? 1 : nil }
        return canGoBackward ? -1 : nil
    }

    /// Begins a turn following the finger. Returns false if nothing can turn that way.
    @discardableResult
    func beginTurn(direction: Int, at screen: CGPoint, auto: Bool = false) -> Bool {
        if turn != nil { return false }
        let pw = layout.pageSize.width, ph = layout.pageSize.height
        let s = slots
        var t: Turn
        if layout.spread {
            if direction > 0 {
                guard canGoForward else { return false }
                t = Turn(direction: 1, mirrored: false, leaf: s.second, back: s.second + 1, under: s.second + 2, stationary: s.first,
                         grab: .zero, finger: .zero, start: .zero, target: .zero, anim: nil, isAuto: auto)
            } else {
                guard canGoBackward else { return false }
                t = Turn(direction: -1, mirrored: true, leaf: s.first, back: s.first - 1, under: s.first - 2, stationary: s.second,
                         grab: .zero, finger: .zero, start: .zero, target: .zero, anim: nil, isAuto: auto)
            }
        } else {
            if direction > 0 {
                guard canGoForward else { return false }
                t = Turn(direction: 1, mirrored: false, leaf: page, back: nil, under: page + 1, stationary: nil,
                         grab: .zero, finger: .zero, start: .zero, target: .zero, anim: nil, isAuto: auto)
            } else {
                guard canGoBackward else { return false }
                t = Turn(direction: -1, mirrored: false, leaf: page - 1, back: nil, under: page, stationary: nil,
                         grab: .zero, finger: .zero, start: .zero, target: .zero, anim: nil, isAuto: auto)
            }
        }
        let flip = layout.baseFlip * (t.mirrored ? -1 : 1)
        let local = layout.local(from: screen, flip: flip)
        var gy = min(max(0, local.y), ph)
        if auto {
            gy = ph
        } else if gy < ph * 0.28 {
            gy = 0
        } else if gy > ph * 0.72 {
            gy = ph
        }
        t.grab = CGPoint(x: pw, y: gy)
        let turned = CGPoint(x: -pw, y: gy)
        let singleBackward = !layout.spread && direction < 0
        t.start = singleBackward ? turned : t.grab
        t.target = singleBackward ? t.grab : turned
        t.finger = t.start
        turn = t
        if !auto { update(finger: screen) }
        return true
    }

    /// Moves the grabbed corner to follow the finger.
    func update(finger screen: CGPoint) {
        guard var t = turn, t.anim == nil else { return }
        let flip = layout.baseFlip * (t.mirrored ? -1 : 1)
        let local = layout.local(from: screen, flip: flip)
        let pw = layout.pageSize.width, ph = layout.pageSize.height
        var f = local
        if !layout.spread {
            // A single page only shows its own width, so amplify the drag to reach the far rest position.
            f.x = 2 * local.x - pw
        }
        f.x = min(f.x, pw)
        f.y = min(max(f.y, -ph * 0.6), ph * 1.6)
        t.finger = tether(f, gy: t.grab.y)
        turn = t
    }

    /// Paper cannot stretch: keep the free corner within reach of its hinge point on the spine.
    private func tether(_ f: CGPoint, gy: CGFloat) -> CGPoint {
        let pw = layout.pageSize.width
        let anchor = CGPoint(x: 0, y: gy)
        let dx = f.x - anchor.x, dy = f.y - anchor.y
        let dist = sqrt(dx * dx + dy * dy)
        let limit = pw * 0.995
        if dist <= limit || dist == 0 { return f }
        return CGPoint(x: anchor.x + dx / dist * limit, y: anchor.y + dy / dist * limit)
    }

    /// Finger lifted: settle to whichever rest position is closer, biased by velocity.
    func endTurn(velocity: CGPoint, now: CFTimeInterval = CACurrentMediaTime()) {
        guard var t = turn, t.anim == nil else { return }
        let flip = layout.baseFlip * (t.mirrored ? -1 : 1)
        let vx = velocity.x * flip * (layout.spread ? 1 : 2)
        var goTarget = t.finger.x < 0
        if t.target.x > 0 { goTarget = t.finger.x > 0 }  // single-page backward turn rests on the right
        if abs(vx) > 350 {
            goTarget = (t.target.x < 0) ? vx < 0 : vx > 0
        }
        let dest = goTarget ? t.target : t.start
        let dist = hypot(dest.x - t.finger.x, dest.y - t.finger.y)
        let dur = min(0.55, max(0.18, Double(dist / (layout.pageSize.width * 2)) * 0.5 + 0.12))
        t.anim = Animation(from: t.finger, to: dest, startTime: now, duration: dur, arc: 0, completes: goTarget)
        turn = t
    }

    /// Full automatic turn (tap on an edge or a button).
    func autoTurn(direction: Int, now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        let pw = layout.pageSize.width
        let ph = layout.pageSize.height
        // Pick a screen point on the correct side so beginTurn resolves the geometry.
        let flip = layout.baseFlip
        let sx = layout.spineX + (direction > 0 ? pw * 0.9 : -pw * 0.9) * flip
        let screen = CGPoint(x: layout.spread ? sx : layout.spineX + (direction > 0 ? pw * 0.9 : pw * 0.1) * flip, y: layout.top + ph * 0.92)
        guard beginTurn(direction: direction, at: screen, auto: true), var t = turn else { return false }
        t.anim = Animation(from: t.start, to: t.target, startTime: now, duration: 0.62, arc: ph * 0.22, completes: true)
        turn = t
        return true
    }

    /// Advances animations. Returns true while something is still moving.
    @discardableResult
    func tick(now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        guard var t = turn, let a = t.anim else { return false }
        let raw = min(1, max(0, (now - a.startTime) / a.duration))
        let e = 1 - pow(1 - raw, 3)   // ease-out cubic
        var p = CGPoint(x: a.from.x + (a.to.x - a.from.x) * e, y: a.from.y + (a.to.y - a.from.y) * e)
        if a.arc != 0 {
            p.y -= sin(e * .pi) * a.arc
        }
        t.finger = tether(p, gy: t.grab.y)
        turn = t
        if raw >= 1 {
            finish(completed: a.completes)
            return false
        }
        return true
    }

    private func finish(completed: Bool) {
        guard let t = turn else { return }
        turn = nil
        if completed {
            let s = slots
            if layout.spread {
                page = t.direction > 0 ? s.second + 1 : max(0, s.first - 1)
            } else {
                page = t.direction > 0 ? page + 1 : page - 1
            }
            page = min(max(0, page), pageCount - 1)
            onPageChanged?(page)
            onTurnCommitted?()
        }
    }

    func cancelTurn() {
        turn = nil
    }

    /// The page shown after moving one spread forward (+1) or back (-1).
    func neighbourPage(_ direction: Int) -> Int {
        let s = slots
        let p = layout.spread ? (direction > 0 ? s.second + 1 : max(0, s.first - 1)) : page + direction
        return min(max(0, p), pageCount - 1)
    }

    /// Jumps one spread without a curl (used by the slide mode once its animation lands).
    func step(_ direction: Int) {
        turn = nil
        page = neighbourPage(direction)
        onPageChanged?(page)
        onTurnCommitted?()
    }

    // MARK: - Curl geometry for rendering

    struct Curl {
        var axisPoint: CGPoint
        var axisNormal: CGPoint
        var radius: CGFloat
        var progress: CGFloat
    }

    /// Cylinder parameters for the current finger position, or nil when the leaf lies flat.
    func curl() -> Curl? {
        guard let t = turn else { return nil }
        let g = t.grab, f = t.finger
        let dx = g.x - f.x, dy = g.y - f.y
        let len = sqrt(dx * dx + dy * dy)
        let pw = layout.pageSize.width
        if len < 0.5 {
            return Curl(axisPoint: CGPoint(x: pw + 1000, y: 0), axisNormal: CGPoint(x: 1, y: 0), radius: 1, progress: 0)
        }
        let n = CGPoint(x: dx / len, y: dy / len)
        let progress = min(1, max(0, len / (2 * pw)))
        let rMax = min(pw * (0.07 + 0.08 * softness), 30 + 40 * softness)
        let rMin = pw * 0.012
        let fade = 1 - smooth((progress - 0.86) / 0.14)
        var r = rMax * sin(progress * .pi) + rMin * fade
        r = max(r, 0.3)
        let dG = (len + .pi * r) / 2
        let c = CGPoint(x: g.x - n.x * dG, y: g.y - n.y * dG)
        return Curl(axisPoint: c, axisNormal: n, radius: r, progress: progress)
    }

    private func smooth(_ x: CGFloat) -> CGFloat {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }
}
