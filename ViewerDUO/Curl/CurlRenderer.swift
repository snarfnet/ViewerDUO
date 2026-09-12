import Foundation
import Metal
import MetalKit
import UIKit

/// Mirrors `Uniforms` in Shaders.metal. Field order matters: two float4, four float2, eight floats = 96 bytes.
struct CurlUniforms {
    var paperTint: SIMD4<Float> = SIMD4(1, 1, 1, 1)
    var viewTransform: SIMD4<Float> = SIMD4(1, 1, 0, 0)
    var quadSize: SIMD2<Float> = SIMD2(1, 1)
    var quadOffset: SIMD2<Float> = SIMD2(0, 0)
    var axisPoint: SIMD2<Float> = SIMD2(0, 0)
    var axisNormal: SIMD2<Float> = SIMD2(1, 0)
    var radius: Float = 0
    var flipX: Float = 1
    var mode: Float = 0
    var backMode: Float = 2
    var shadow: Float = 0
    var zBase: Float = 0
    var tint: Float = 1
    var spineSide: Float = 0
}

/// One textured rectangle in the draw list, expressed in leaf-local points.
struct QuadSpec {
    var origin: CGPoint
    var size: CGSize
    var front: MTLTexture?
    var back: MTLTexture?
    var mode: Float = 0
    var backMode: Float = 2
    var shadow: Float = 0
    var zBase: Float = 0
    var tint: Float = 1
    var spineSide: Float = 0
}

/// Everything the renderer needs for one frame.
struct CurlScene {
    var viewSize: CGSize = .zero
    var scale: CGFloat = 2
    /// Screen position (points) of the leaf-local origin (the spine at the page's top edge).
    var origin: CGPoint = .zero
    var flipX: Float = 1
    var axisPoint: CGPoint = .zero
    var axisNormal: CGPoint = CGPoint(x: 1, y: 0)
    var radius: CGFloat = 0
    var paper: UIColor = .white
    var quads: [QuadSpec] = []
}

final class CurlRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let indexCount: Int
    private var blankTexture: MTLTexture?
    private var blankColor: UIColor?

    static let cols = 48
    static let rows = 64

    init?(device: MTLDevice, colorFormat: MTLPixelFormat, sampleCount: Int) {
        self.device = device
        guard let q = device.makeCommandQueue(), let lib = device.makeDefaultLibrary(),
              let vf = lib.makeFunction(name: "page_vertex"), let ff = lib.makeFunction(name: "page_fragment") else { return nil }
        queue = q
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vf
        desc.fragmentFunction = ff
        desc.colorAttachments[0].pixelFormat = colorFormat
        desc.depthAttachmentPixelFormat = .depth32Float
        desc.rasterSampleCount = sampleCount
        guard let p = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        pipeline = p
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: dd) else { return nil }
        depthState = ds

        // Unit grid mesh; the vertex shader scales it to each quad.
        let cols = Self.cols, rows = Self.rows
        var verts: [SIMD2<Float>] = []
        verts.reserveCapacity((cols + 1) * (rows + 1))
        for r in 0...rows {
            for c in 0...cols {
                verts.append(SIMD2(Float(c) / Float(cols), Float(r) / Float(rows)))
            }
        }
        var idx: [UInt16] = []
        idx.reserveCapacity(cols * rows * 6)
        for r in 0..<rows {
            for c in 0..<cols {
                let a = UInt16(r * (cols + 1) + c)
                let b = a + 1
                let cc = UInt16((r + 1) * (cols + 1) + c)
                let d = cc + 1
                // Clockwise on screen (y down) so the flat page is front-facing.
                idx += [a, b, cc, b, d, cc]
            }
        }
        guard let vb = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared),
              let ib = device.makeBuffer(bytes: idx, length: idx.count * MemoryLayout<UInt16>.stride, options: .storageModeShared) else { return nil }
        vertexBuffer = vb
        indexBuffer = ib
        indexCount = idx.count
    }

    // MARK: - Textures

    func makeTexture(from image: CGImage) -> MTLTexture? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: true)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ok: Bool = data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: cs, bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        data.withUnsafeBytes { buf in
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: buf.baseAddress!, bytesPerRow: bytesPerRow)
        }
        if let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cmd.commit()
        }
        return tex
    }

    func blank(for color: UIColor) -> MTLTexture? {
        if let t = blankTexture, let c = blankColor, c == color { return t }
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 4, height: 4, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        let px: [UInt8] = [UInt8(b * 255), UInt8(g * 255), UInt8(r * 255), 255]
        var data: [UInt8] = []
        for _ in 0..<16 { data += px }
        data.withUnsafeBytes { buf in
            tex.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: buf.baseAddress!, bytesPerRow: 16)
        }
        blankTexture = tex
        blankColor = color
        return tex
    }

    // MARK: - Drawing

    func draw(in view: MTKView, scene: CurlScene) {
        guard let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setFrontFacing(.clockwise)
        enc.setCullMode(.none)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        let vw = Float(max(1, scene.viewSize.width)), vh = Float(max(1, scene.viewSize.height))
        let ox = Float(scene.origin.x), oy = Float(scene.origin.y)
        let transform = SIMD4<Float>(2 / vw, -2 / vh, 2 * ox / vw - 1, 1 - 2 * oy / vh)
        var pr: CGFloat = 1, pg: CGFloat = 1, pb: CGFloat = 1, pa: CGFloat = 1
        scene.paper.getRed(&pr, green: &pg, blue: &pb, alpha: &pa)
        let tint = SIMD4<Float>(Float(pr), Float(pg), Float(pb), 1)
        let blankTex = blank(for: scene.paper)

        for q in scene.quads {
            var u = CurlUniforms()
            u.paperTint = tint
            u.viewTransform = transform
            u.quadSize = SIMD2(Float(q.size.width), Float(q.size.height))
            u.quadOffset = SIMD2(Float(q.origin.x), Float(q.origin.y))
            u.axisPoint = SIMD2(Float(scene.axisPoint.x), Float(scene.axisPoint.y))
            u.axisNormal = SIMD2(Float(scene.axisNormal.x), Float(scene.axisNormal.y))
            u.radius = Float(scene.radius)
            u.flipX = scene.flipX
            u.mode = q.mode
            u.backMode = q.backMode
            u.shadow = q.shadow
            u.zBase = q.zBase
            u.tint = q.tint
            u.spineSide = q.spineSide
            enc.setVertexBytes(&u, length: MemoryLayout<CurlUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<CurlUniforms>.stride, index: 1)
            enc.setFragmentTexture(q.front ?? blankTex, index: 0)
            enc.setFragmentTexture(q.back ?? blankTex, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint16, indexBuffer: indexBuffer, indexBufferOffset: 0)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
