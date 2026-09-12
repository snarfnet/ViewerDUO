import SwiftUI
import MetalKit
import UIKit

/// SwiftUI wrapper around the Metal page-curl surface.
struct PageCurlView: UIViewRepresentable {
    @ObservedObject var controller: CurlController
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.displayScale) private var displayScale

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> MTKView {
        let view = CurlMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.clearDepth = 1
        view.isOpaque = false
        view.backgroundColor = .clear
        view.layer.isOpaque = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.framebufferOnly = true
        view.delegate = context.coordinator
        view.isMultipleTouchEnabled = false
        if let device = view.device, let renderer = CurlRenderer(device: device, colorFormat: view.colorPixelFormat, sampleCount: view.sampleCount) {
            context.coordinator.renderer = renderer
            controller.attach(renderer: renderer, view: view)
        }
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        view.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap(_:)))
        single.require(toFail: double)
        view.addGestureRecognizer(single)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.regularWidth = hSize == .regular
        context.coordinator.displayScale = displayScale
        context.coordinator.pushEnvironment()
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.controller.stopAnimating()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let controller: CurlController
        var renderer: CurlRenderer?
        weak var view: MTKView?
        var regularWidth = false
        var displayScale: CGFloat = 2
        private var panActive = false

        init(controller: CurlController) {
            self.controller = controller
        }

        func pushEnvironment() {
            guard let view else { return }
            controller.updateEnvironment(viewSize: view.bounds.size, regularWidth: regularWidth, displayScale: displayScale)
        }

        // MARK: MTKViewDelegate

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            pushEnvironment()
        }

        func draw(in view: MTKView) {
            guard let renderer else { return }
            if view.bounds.size != .zero, controller.engine.layout.viewSize != view.bounds.size {
                pushEnvironment()
            }
            renderer.draw(in: view, scene: controller.buildScene())
        }

        // MARK: Gestures

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let view else { return }
            let p = g.location(in: view)
            switch g.state {
            case .began:
                panActive = controller.panBegan(at: p)
            case .changed:
                if panActive { controller.panMoved(to: p) }
            case .ended, .cancelled, .failed:
                if panActive {
                    controller.panEnded(velocity: g.velocity(in: view))
                }
                panActive = false
            default:
                break
            }
        }

        @objc func singleTap(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            controller.tap(at: g.location(in: view))
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            controller.doubleTap(at: g.location(in: view))
        }
    }
}

/// MTKView that reports layout changes so the book can be re-fitted when the window resizes or folds.
final class CurlMTKView: MTKView {
    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }
}
