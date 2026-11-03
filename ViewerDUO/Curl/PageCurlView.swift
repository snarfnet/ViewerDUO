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
        let view: CurlMTKView = CurlMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
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
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = context.coordinator
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pinch)
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        view.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap(_:)))
        single.require(toFail: double)
        view.addGestureRecognizer(single)
        context.coordinator.view = view
        // Hardware keyboard and VoiceOver turn pages through the same animated path as a tap.
        let c = controller
        view.onStep = { [weak c] direction in _ = c?.turn(direction: direction) }
        view.onActivate = { [weak c] in c?.onCenterTap?() }
        view.isAccessibilityElement = true
        view.accessibilityTraits = .adjustable
        view.accessibilityLabel = L10n.bookPage
        view.accessibilityHint = L10n.pageTurnA11yHint
        if #available(iOS 27.1, *) {
            // Folding or unfolding iPhone Duo moves the division region; lay the book out again when it does.
            let hinge = UIHingeInteraction { [weak coordinator = context.coordinator] _, _ in
                coordinator?.pushEnvironment()
            }
            view.addInteraction(hinge)
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.regularWidth = hSize == .regular
        context.coordinator.displayScale = displayScale
        context.coordinator.pushEnvironment()
        if let v = view as? CurlMTKView {
            v.rightToLeft = controller.rightToLeft
            v.accessibilityValue = "\(controller.page + 1) / \(controller.pageCount)"
            v.takeKeyboardFocusIfFree()
        }
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.controller.stopAnimating()
    }

    final class Coordinator: NSObject, MTKViewDelegate, UIGestureRecognizerDelegate {
        let controller: CurlController
        var renderer: CurlRenderer?
        weak var view: MTKView?
        var regularWidth = false
        var displayScale: CGFloat = 2
        private var panActive = false
        private var pinchFired = false

        init(controller: CurlController) {
            self.controller = controller
        }

        func pushEnvironment() {
            guard let view else { return }
            let fold = Self.verticalFold(in: view)
            controller.updateEnvironment(viewSize: view.bounds.size, regularWidth: regularWidth, displayScale: displayScale,
                                         hingeX: fold?.x, hingeGap: fold?.gap ?? 0)
        }

        /// The fold of an open iPhone Duo when it runs top to bottom through this view; it becomes the spine.
        static func verticalFold(in view: UIView) -> (x: CGFloat, gap: CGFloat)? {
            guard #available(iOS 27.1, *) else { return nil }
            let bounds = view.bounds
            for r in view.reservedRegions(kind: .division) where r.isActive {
                let f = r.frame
                guard f.height >= f.width, f.midX > bounds.minX + 40, f.midX < bounds.maxX - 40 else { continue }
                return (f.midX - bounds.minX, f.width + r.margins.left + r.margins.right)
            }
            return nil
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

        /// Spreading two fingers on a page opens it in the zoom viewer (same as a double tap).
        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard let view else { return }
            switch g.state {
            case .began:
                pinchFired = false
                if panActive {
                    controller.panEnded(velocity: .zero)
                    panActive = false
                }
            case .changed:
                if !pinchFired, g.scale > 1.12 {
                    pinchFired = true
                    controller.doubleTap(at: g.location(in: view))
                }
            default:
                break
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            g is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
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
/// It also takes arrow keys / space from a hardware keyboard and VoiceOver's adjust gesture.
final class CurlMTKView: MTKView {
    /// +1 turns forward in reading order, -1 back.
    var onStep: ((Int) -> Void)?
    var onActivate: (() -> Void)?
    /// In a right-to-left book the left arrow key moves forward.
    var rightToLeft = false

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        takeKeyboardFocusIfFree()
    }

    /// Becomes first responder unless a sheet is up (its text field must keep the keyboard).
    func takeKeyboardFocusIfFree() {
        guard window != nil, !isFirstResponder else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !self.isFirstResponder,
                  window.rootViewController?.presentedViewController == nil else { return }
            self.becomeFirstResponder()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        let left = UIKeyCommand(title: rightToLeft ? L10n.nextPage : L10n.previousPage, action: #selector(keyLeft),
                                input: UIKeyCommand.inputLeftArrow)
        let right = UIKeyCommand(title: rightToLeft ? L10n.previousPage : L10n.nextPage, action: #selector(keyRight),
                                 input: UIKeyCommand.inputRightArrow)
        let commands = [
            left, right,
            UIKeyCommand(action: #selector(keyForward), input: " "),
            UIKeyCommand(action: #selector(keyBackward), input: " ", modifierFlags: .shift),
            UIKeyCommand(action: #selector(keyForward), input: UIKeyCommand.inputPageDown),
            UIKeyCommand(action: #selector(keyBackward), input: UIKeyCommand.inputPageUp),
            UIKeyCommand(action: #selector(keyForward), input: UIKeyCommand.inputDownArrow),
            UIKeyCommand(action: #selector(keyBackward), input: UIKeyCommand.inputUpArrow),
        ]
        for c in commands { c.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func keyLeft() { onStep?(rightToLeft ? 1 : -1) }
    @objc private func keyRight() { onStep?(rightToLeft ? -1 : 1) }
    @objc private func keyForward() { onStep?(1) }
    @objc private func keyBackward() { onStep?(-1) }

    // MARK: VoiceOver

    override func accessibilityIncrement() { onStep?(1) }
    override func accessibilityDecrement() { onStep?(-1) }
    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }
}
