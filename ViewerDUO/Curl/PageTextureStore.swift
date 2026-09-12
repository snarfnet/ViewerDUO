import Foundation
import Metal
import UIKit

/// Renders pages on a background queue and keeps the resulting Metal textures for the pages near the reader.
final class PageTextureStore {
    private let renderer: CurlRenderer
    private let queue: DispatchQueue
    private var textures: [Int: MTLTexture] = [:]
    private var pending: Set<Int> = []
    private var generation = 0
    private(set) var pageSize: CGSize = .zero
    private(set) var scale: CGFloat = 2
    private var style: TextStyle?
    private var source: PageSource?
    /// Called on the main thread whenever a texture becomes available.
    var onReady: (() -> Void)?

    init(renderer: CurlRenderer, queue: DispatchQueue) {
        self.renderer = renderer
        self.queue = queue
    }

    func configure(source: PageSource?, pageSize: CGSize, scale: CGFloat, style: TextStyle) {
        let changed = source !== self.source || pageSize != self.pageSize || scale != self.scale || style != self.style
        guard changed else { return }
        self.source = source
        self.pageSize = pageSize
        self.scale = scale
        self.style = style
        generation += 1
        textures.removeAll()
        pending.removeAll()
    }

    func invalidate() {
        generation += 1
        textures.removeAll()
        pending.removeAll()
    }

    /// Returns the texture if it is ready; otherwise schedules rendering and returns nil.
    func texture(for page: Int) -> MTLTexture? {
        if let t = textures[page] { return t }
        request(page)
        return nil
    }

    func prefetch(_ pages: [Int]) {
        for p in pages where textures[p] == nil { request(p) }
        trim(keeping: pages)
    }

    private func request(_ page: Int) {
        guard let source, let style, pageSize.width > 10, !pending.contains(page), page >= 0, page < source.pageCount else { return }
        pending.insert(page)
        let gen = generation
        let size = pageSize, sc = scale
        queue.async { [weak self] in
            guard let self else { return }
            let image = source.render(page: page, size: size, scale: sc, style: style)
            let tex = image.flatMap { self.renderer.makeTexture(from: $0) }
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.pending.remove(page)
                if let tex { self.textures[page] = tex }
                self.onReady?()
            }
        }
    }

    private func trim(keeping: [Int]) {
        guard textures.count > 12 else { return }
        let keep = Set(keeping)
        let center = keeping.first ?? 0
        let victims = textures.keys.filter { !keep.contains($0) }.sorted { abs($0 - center) > abs($1 - center) }
        for v in victims.prefix(textures.count - 12) { textures.removeValue(forKey: v) }
    }
}
