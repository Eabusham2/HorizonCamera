import SwiftUI
import MetalKit
import CoreImage

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
                let scale = min(bounds.width/e.width,bounds.height/e.height)
                let transformed = source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                    .transformed(by:CGAffineTransform(translationX:(bounds.width-e.width*scale)/2,
                                                       y:(bounds.height-e.height*scale)/2))
                image = transformed.composited(over:image)
            }
            parent.renderer.context.render(image,to:drawable.texture,commandBuffer:command,bounds:bounds,colorSpace:parent.renderer.colorSpace)
            command.present(drawable); command.commit()
        }
        private func point(_ recognizer: UIGestureRecognizer) -> Point2? {
            guard let view = recognizer.view, let frame = parent.feed.snapshot() else { return nil }
            let size = frame.image.extent.size
            let scale = min(view.bounds.width/size.width,view.bounds.height/size.height)
            let rect = CGRect(x:(view.bounds.width-size.width*scale)/2,y:(view.bounds.height-size.height*scale)/2,
                              width:size.width*scale,height:size.height*scale)
            let point = recognizer.location(in:view)
            guard rect.contains(point), rect.width > 0, rect.height > 0 else { return nil }
            return Point2((point.x-rect.minX)/rect.width,(point.y-rect.minY)/rect.height)
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
