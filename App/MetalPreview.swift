import SwiftUI
import MetalKit
import CoreImage

struct PreviewLayout {
    static func aspectFit(image: CGSize, in bounds: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width/image.width,bounds.height/image.height)
        let size = CGSize(width:image.width*scale,height:image.height*scale)
        return CGRect(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2,width:size.width,height:size.height)
    }
    static func normalizedUIKitPoint(_ point: CGPoint, image: CGSize, in bounds: CGSize) -> Point2? {
        let rect = aspectFit(image:image,in:bounds)
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        return Point2((point.x-rect.minX)/rect.width,(point.y-rect.minY)/rect.height)
    }
}

struct MetalPreview: UIViewRepresentable {
    let feed: PreviewFeed
    let renderer: ImageRenderer
    var overview = false
    var zoom: () -> Double = { 1 }
    var tap: (Point2) -> Void = { _ in }
    var pinch: (Double, Point2) -> Void = { _,_ in }
    var hold: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame:.zero,device:renderer.device)
        view.framebufferOnly = false; view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = overview ? 30 : 60
        view.isPaused = false; view.enableSetNeedsDisplay = false
        view.isOpaque = true; view.backgroundColor = .black
        view.delegate = context.coordinator
        if !overview {
            let tap = UITapGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.tapped(_:)))
            let pinch = UIPinchGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.pinched(_:)))
            let hold = UILongPressGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.held(_:)))
            hold.minimumPressDuration = 0.6
            view.addGestureRecognizer(tap); view.addGestureRecognizer(pinch); view.addGestureRecognizer(hold)
            tap.require(toFail:hold)
        }
        return view
    }
    func updateUIView(_ uiView: MTKView, context: Context) { context.coordinator.parent = self }
    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) { uiView.isPaused = true; uiView.delegate = nil }
    final class Coordinator: NSObject, MTKViewDelegate {
        var parent: MetalPreview
        private let queue: MTLCommandQueue?
        private var startZoom = 1.0
        init(_ parent: MetalPreview) { self.parent = parent; queue = parent.renderer.device.makeCommandQueue() }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable, let command = queue?.makeCommandBuffer() else { return }
            let bounds = CGRect(origin:.zero,size:view.drawableSize)
            guard bounds.width > 0 && bounds.height > 0 else { return }
            var image = CIImage(color:.black).cropped(to:bounds)
            if let frame = parent.feed.snapshot() {
                let source = parent.overview ? frame.overview : frame.image
                let e = source.extent
                let rect = PreviewLayout.aspectFit(image:e.size,in:bounds.size)
                let scale = rect.width/e.width
                let transformed = source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                    .transformed(by:CGAffineTransform(translationX:rect.minX-e.minX*scale,
                                                       y:rect.minY-e.minY*scale))
                image = transformed.composited(over:image)
            }
            parent.renderer.context.render(image,to:drawable.texture,commandBuffer:command,bounds:bounds,colorSpace:parent.renderer.colorSpace)
            command.present(drawable); command.commit()
        }
        private func point(_ recognizer: UIGestureRecognizer) -> Point2? {
            guard let view = recognizer.view, let frame = parent.feed.snapshot() else { return nil }
            let size = frame.image.extent.size
            return PreviewLayout.normalizedUIKitPoint(recognizer.location(in:view),image:size,in:view.bounds.size)
        }
        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            if let point = point(recognizer) { parent.tap(point) }
        }
        @objc func pinched(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .began { startZoom = parent.zoom() }
            if let point = point(recognizer) { parent.pinch(startZoom*Double(recognizer.scale),point) }
        }
        @objc func held(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began { parent.hold() }
        }
    }
}
