import Foundation
import SwiftUI
import MetalKit
import UIKit

/// Bridges the SwiftUI reader, the page source and the Metal curl engine. Main thread only.
final class CurlController: ObservableObject {
    @Published private(set) var page = 0
    @Published private(set) var pageCount = 1
    @Published private(set) var chapters: [Chapter] = []
    @Published private(set) var isLoading = true
    @Published private(set) var failed = false
    @Published private(set) var spread = false
    @Published private(set) var isTurning = false

    let engine = CurlEngine()
    let renderQueue = DispatchQueue(label: "duo.render", qos: .userInitiated)
    private(set) var source: PageSource?
    private(set) var renderer: CurlRenderer?
    private(set) var store: PageTextureStore?
    weak var view: MTKView?

    // Environment fed from SwiftUI.
    var layoutMode: LayoutMode = .auto
    var rightToLeft = false
    var style = TextStyle(paper: PaperStyle.named("cream"), font: .serif, fontSize: 17, lineSpacing: 1.7, margin: 1, vertical: false)
    var coverAlone = true
    var showStack = true
    var softness: CGFloat = 0.5
    /// Screen x of the fold on iPhone Duo (reserved division region). Nil = centre of the view.
    var hingeX: CGFloat?
    var hingeGap: CGFloat = 0
    private var viewSize: CGSize = .zero
    private var regularWidth = false
    private var displayScale: CGFloat = 2
    private var loadToken = 0

    var onCenterTap: (() -> Void)?
    var onDoubleTap: ((Int) -> Void)?
    var onTurnBegan: (() -> Void)?
    var onTurnCommitted: (() -> Void)?
    var onBlocked: (() -> Void)?

    init() {
        engine.onPageChanged = { [weak self] p in
            guard let self else { return }
            self.page = p
            self.prefetch()
        }
        engine.onTurnCommitted = { [weak self] in
            self?.isTurning = false
            self?.onTurnCommitted?()
        }
    }

    var currentOffset: Int { source?.offset(forPage: page) ?? page }

    // MARK: - Loading

    func open(book: Book, url: URL, startPage: Int, startOffset: Int) {
        loadToken += 1
        let token = loadToken
        isLoading = true
        failed = false
        source = nil
        engine.cancelTurn()
        let format = book.format
        let id = book.id
        let title = book.title
        renderQueue.async { [weak self] in
            var src: PageSource?
            switch format {
            case .pdf:
                src = PDFSource(url: url)
            case .zip, .rar:
                if let pages = try? ArchiveExtractor.imagePages(fileURL: url, format: format, bookID: id), !pages.isEmpty {
                    src = ImageSource(urls: pages)
                }
            case .txt:
                src = TextSource(plainTextURL: url, title: title)
            case .epub:
                if let pkg = try? EPUBParser.open(fileURL: url, bookID: id) {
                    src = TextSource(epub: pkg, title: title)
                }
            }
            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                guard let src else {
                    self.failed = true
                    self.isLoading = false
                    return
                }
                self.source = src
                self.pageCount = src.pageCount
                self.chapters = src.chapters
                self.engine.pageCount = src.pageCount
                self.pendingStart = src.isReflowable ? (startOffset, true) : nil
                self.isLoading = src.isReflowable
                if !src.isReflowable {
                    self.page = min(max(0, startPage), src.pageCount - 1)
                    self.engine.page = self.page
                }
                self.relayout(force: true)
            }
        }
    }

    /// Position to restore once a reflowable source has been paginated for the first time.
    private var pendingStart: (Int, Bool)?

    func attach(renderer: CurlRenderer, view: MTKView) {
        self.renderer = renderer
        self.view = view
        let s = PageTextureStore(renderer: renderer, queue: renderQueue)
        s.onReady = { [weak self] in self?.requestDraw() }
        store = s
        relayout(force: true)
    }

    // MARK: - Layout

    func updateEnvironment(viewSize: CGSize, regularWidth: Bool, displayScale: CGFloat) {
        var changed = false
        if viewSize != self.viewSize { self.viewSize = viewSize; changed = true }
        if regularWidth != self.regularWidth { self.regularWidth = regularWidth; changed = true }
        let sc = min(displayScale, 2)
        if sc != self.displayScale { self.displayScale = sc; changed = true }
        if changed { relayout(force: false) }
    }

    func applySettings(layoutMode: LayoutMode, rightToLeft: Bool, style: TextStyle, coverAlone: Bool, showStack: Bool, softness: CGFloat) {
        var changed = false
        if layoutMode != self.layoutMode { self.layoutMode = layoutMode; changed = true }
        if rightToLeft != self.rightToLeft { self.rightToLeft = rightToLeft; changed = true }
        if style != self.style { self.style = style; changed = true }
        if coverAlone != self.coverAlone { self.coverAlone = coverAlone; engine.coverAlone = coverAlone; changed = true }
        if showStack != self.showStack { self.showStack = showStack; changed = true }
        engine.softness = softness
        if changed { relayout(force: true) }
        else { requestDraw() }
    }

    private var effectiveSpread: Bool {
        switch layoutMode {
        case .single: return false
        case .spread: return viewSize.width > 320
        case .auto: return regularWidth && viewSize.width >= 600
        }
    }

    private var lastLayoutKey = ""

    private func relayout(force: Bool) {
        guard viewSize.width > 10, viewSize.height > 10 else { return }
        let aspect = source?.aspect ?? 1.45
        let sp = effectiveSpread
        let layout = BookLayout.make(viewSize: viewSize, spread: sp, rtl: rightToLeft, aspect: aspect, hingeX: sp ? hingeX : nil, hingeGap: sp ? hingeGap : 0)
        let key = "\(layout.pageSize)-\(sp)-\(rightToLeft)-\(style.fontSize)-\(style.font)-\(style.lineSpacing)-\(style.margin)-\(style.vertical)-\(style.paper.id)-\(displayScale)-\(coverAlone)"
        guard force || key != lastLayoutKey || layout != engine.layout else { return }
        lastLayoutKey = key
        engine.cancelTurn()
        isTurning = false
        engine.layout = layout
        engine.coverAlone = coverAlone
        spread = sp
        guard let source else {
            requestDraw()
            return
        }
        if source.isReflowable {
            let pending = pendingStart?.0
            let currentPage = page
            let size = layout.pageSize
            let st = style
            let token = loadToken
            isLoading = true
            renderQueue.async { [weak self] in
                let offset = pending ?? source.offset(forPage: currentPage)
                source.prepare(pageSize: size, style: st)
                let count = source.pageCount
                let newPage = source.page(forOffset: offset)
                let chapters = source.chapters
                DispatchQueue.main.async {
                    guard let self, token == self.loadToken else { return }
                    self.pendingStart = nil
                    self.pageCount = count
                    self.chapters = chapters
                    self.engine.pageCount = count
                    self.page = min(max(0, newPage), count - 1)
                    self.engine.page = self.page
                    self.store?.configure(source: source, pageSize: size, scale: self.displayScale, style: st)
                    self.isLoading = false
                    self.prefetch()
                    self.requestDraw()
                }
            }
        } else {
            store?.configure(source: source, pageSize: layout.pageSize, scale: displayScale, style: style)
            isLoading = false
            prefetch()
            requestDraw()
        }
    }

    private func prefetch() {
        store?.prefetch(engine.neededPages)
    }

    func requestDraw() {
        view?.setNeedsDisplay()
    }

    // MARK: - Navigation

    func goTo(page target: Int) {
        guard !isLoading else { return }
        let p = min(max(0, target), pageCount - 1)
        engine.cancelTurn()
        isTurning = false
        engine.page = p
        page = p
        prefetch()
        requestDraw()
    }

    func goTo(offset: Int) {
        guard let source, source.isReflowable else { goTo(page: offset); return }
        goTo(page: source.page(forOffset: offset))
    }

    /// Animated turn in the reading direction (+1) or back (-1).
    func turn(direction: Int) -> Bool {
        guard !isLoading, !engine.isTurning else { return false }
        if engine.autoTurn(direction: direction) {
            isTurning = true
            onTurnBegan?()
            startAnimating()
            return true
        }
        onBlocked?()
        return false
    }

    func nextPageAvailable() -> Bool { engine.canGoForward }
    func previousPageAvailable() -> Bool { engine.canGoBackward }

    // MARK: - Gestures (called by the view coordinator)

    func panBegan(at screen: CGPoint) -> Bool {
        guard !isLoading, !engine.isTurning, let dir = engine.directionForTouch(at: screen) else {
            if !isLoading && !engine.isTurning { onBlocked?() }
            return false
        }
        if engine.beginTurn(direction: dir, at: screen) {
            isTurning = true
            onTurnBegan?()
            requestDraw()
            return true
        }
        return false
    }

    func panMoved(to screen: CGPoint) {
        engine.update(finger: screen)
        requestDraw()
    }

    func panEnded(velocity: CGPoint) {
        engine.endTurn(velocity: velocity)
        startAnimating()
    }

    func tap(at screen: CGPoint) {
        guard !isLoading else { return }
        let layout = engine.layout
        let p = layout.local(from: screen, flip: layout.baseFlip)
        let pw = layout.pageSize.width
        if layout.spread {
            if p.x > pw * 0.72 { _ = turn(direction: 1); return }
            if p.x < -pw * 0.72 { _ = turn(direction: -1); return }
        } else {
            if p.x > pw * 0.78 { _ = turn(direction: 1); return }
            if p.x < pw * 0.22 { _ = turn(direction: -1); return }
        }
        onCenterTap?()
    }

    func doubleTap(at screen: CGPoint) {
        guard !isLoading else { return }
        let layout = engine.layout
        let p = layout.local(from: screen, flip: layout.baseFlip)
        let s = engine.slots
        var target = page
        if layout.spread { target = p.x >= 0 ? s.second : s.first }
        guard engine.isValid(target) else { return }
        onDoubleTap?(target)
    }

    /// Advances animation; returns true while still moving.
    func tick() -> Bool {
        let moving = engine.tick()
        requestDraw()
        if !moving && engine.turn == nil { isTurning = false }
        return moving
    }

    // MARK: - Display link

    private final class LinkTarget: NSObject {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func fire() { handler() }
    }

    private var link: CADisplayLink?
    private var linkTarget: LinkTarget?

    func startAnimating() {
        guard link == nil else { return }
        let target = LinkTarget { [weak self] in
            guard let self else { return }
            if !self.tick() { self.stopAnimating() }
        }
        linkTarget = target
        let l = CADisplayLink(target: target, selector: #selector(LinkTarget.fire))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stopAnimating() {
        link?.invalidate()
        link = nil
        linkTarget = nil
    }

    // MARK: - Scene

    func buildScene() -> CurlScene {
        var scene = CurlScene()
        scene.viewSize = viewSize
        scene.scale = displayScale
        scene.origin = engine.layout.origin
        scene.flipX = Float(engine.flipX)
        scene.paper = style.paper.background
        guard let store else { return scene }
        let pw = engine.layout.pageSize.width, ph = engine.layout.pageSize.height
        let size = engine.layout.pageSize
        let s = engine.slots
        let flip = engine.flipX

        func tex(_ i: Int) -> MTLTexture? {
            engine.isValid(i) ? store.texture(for: i) : nil
        }

        // Page stacks (thickness) on the physical left/right of the book.
        if showStack {
            let after = max(0, pageCount - 1 - (engine.layout.spread ? s.second : page))
            let before = max(0, engine.layout.spread ? s.first : page)
            let denom = CGFloat(max(1, pageCount - 1))
            func strips(_ n: Int) -> Int { n <= 0 ? 0 : min(7, max(1, Int((CGFloat(n) / denom * 7).rounded(.up)))) }
            let screenRight = rightToLeft ? strips(before) : strips(after)
            let screenLeft = rightToLeft ? strips(after) : strips(before)
            let localRight = flip > 0 ? screenRight : screenLeft
            let localLeft = flip > 0 ? screenLeft : screenRight
            for i in stride(from: localRight, through: 1, by: -1) {
                let fi = CGFloat(i)
                scene.quads.append(QuadSpec(origin: CGPoint(x: 0, y: 0.7 * fi), size: CGSize(width: pw + 1.5 * fi, height: ph - 0.4 * fi),
                                            zBase: Float(-3 - i), tint: Float(0.97 - 0.035 * Double(i))))
            }
            if engine.layout.spread {
                for i in stride(from: localLeft, through: 1, by: -1) {
                    let fi = CGFloat(i)
                    scene.quads.append(QuadSpec(origin: CGPoint(x: -(pw + 1.5 * fi), y: 0.7 * fi), size: CGSize(width: pw + 1.5 * fi, height: ph - 0.4 * fi),
                                                zBase: Float(-3 - i), tint: Float(0.97 - 0.035 * Double(i))))
                }
            }
        }

        if let t = engine.turn, let c = engine.curl() {
            scene.axisPoint = c.axisPoint
            scene.axisNormal = c.axisNormal
            scene.radius = c.radius
            let shadow: Float = 0.42
            if engine.layout.spread, let st = t.stationary {
                scene.quads.append(QuadSpec(origin: CGPoint(x: -pw, y: 0), size: size, front: tex(st), shadow: shadow, zBase: -2, spineSide: 2))
            }
            scene.quads.append(QuadSpec(origin: .zero, size: size, front: tex(t.under), shadow: shadow, zBase: -2, spineSide: 1))
            var leaf = QuadSpec(origin: .zero, size: size, front: tex(t.leaf), mode: 1, zBase: 0, spineSide: 1)
            if let b = t.back {
                if engine.isValid(b) {
                    leaf.back = tex(b)
                    leaf.backMode = leaf.back == nil ? 2 : 0
                } else {
                    leaf.backMode = 2
                }
            } else {
                leaf.backMode = 1
            }
            scene.quads.append(leaf)
        } else if engine.layout.spread {
            scene.quads.append(QuadSpec(origin: CGPoint(x: -pw, y: 0), size: size, front: tex(s.first), zBase: -2, spineSide: 2))
            scene.quads.append(QuadSpec(origin: .zero, size: size, front: tex(s.second), zBase: -2, spineSide: 1))
        } else {
            scene.quads.append(QuadSpec(origin: .zero, size: size, front: tex(page), zBase: -2, spineSide: 1))
        }
        return scene
    }

    // MARK: - Screenshot support

    /// Freezes a half-turned page so App Store screenshots show the curl.
    func freezeDemoCurl() {
        guard !isLoading, engine.canGoForward else { return }
        let layout = engine.layout
        let pw = layout.pageSize.width, ph = layout.pageSize.height
        let flip = layout.baseFlip
        let grabScreen = CGPoint(x: layout.spineX + pw * 0.95 * flip, y: layout.top + ph * 0.9)
        guard engine.beginTurn(direction: 1, at: grabScreen) else { return }
        let localX: CGFloat = layout.spread ? pw * 0.12 : pw * 0.56
        let fingerScreen = CGPoint(x: layout.spineX + localX * flip, y: layout.top + ph * 0.58)
        engine.update(finger: fingerScreen)
        isTurning = true
        requestDraw()
    }

    // MARK: - Search & zoom

    func search(_ query: String, completion: @escaping ([SearchHit]) -> Void) {
        guard let source, source.supportsSearch else { completion([]); return }
        renderQueue.async {
            let hits = source.search(query)
            DispatchQueue.main.async { completion(hits) }
        }
    }

    func renderForZoom(page: Int, completion: @escaping (UIImage?) -> Void) {
        guard let source else { completion(nil); return }
        let size = engine.layout.pageSize
        let st = style
        renderQueue.async {
            let img = source.render(page: page, size: size, scale: 3, style: st)
            DispatchQueue.main.async { completion(img.map { UIImage(cgImage: $0) }) }
        }
    }

    var supportsSearch: Bool { source?.supportsSearch ?? false }
}
