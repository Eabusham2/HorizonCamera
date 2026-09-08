import Foundation
import CoreImage
import Metal
import CoreVideo

struct PreviewFrame {
    let image: CIImage
    let overview: CIImage
    let plan: CropPlan
    let target: Point2?
    let trackingGood: Bool
    let diagnostics: FrameDiagnostics
}
/// Holds only ONE latest frame. Slow UI consumers cannot accumulate camera buffers.
final class PreviewFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PreviewFrame?
    func publish(_ frame: PreviewFrame?) { lock.lock(); value = frame; lock.unlock() }
    func snapshot() -> PreviewFrame? { lock.lock(); defer { lock.unlock() }; return value }
}
final class ImageRenderer: @unchecked Sendable {
    let device: MTLDevice
    let context: CIContext
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    }
    func transform(_ image: CIImage, plan: CropPlan) -> CIImage {
        let c = cos(plan.angle), s = sin(plan.angle), z = plan.scale
        let transform = CGAffineTransform(a: z*c, b: z*s, c: -z*s, d: z*c,
            tx: plan.output.width/2-z*(c*plan.center.x-s*plan.center.y),
            ty: plan.output.height/2-z*(s*plan.center.x+c*plan.center.y))
        return image.transformed(by: transform).cropped(to: CGRect(x: 0, y: 0,
            width: plan.output.width, height: plan.output.height))
    }
    func filter(_ image: CIImage, _ filter: CaptureFilter) -> CIImage {
        switch filter {
        case .original: return image
        case .noir: return image.applyingFilter("CIPhotoEffectNoir")
        case .vivid: return image.applyingFilter("CIColorControls", parameters: ["inputSaturation": 1.2, "inputContrast": 1.08])
        case .warm: return image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500,y: 0), "inputTargetNeutral": CIVector(x: 7600,y: 0)])
        case .cool: return image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500,y: 0), "inputTargetNeutral": CIVector(x: 5400,y: 0)])
        }
    }
    func render(_ image: CIImage, into buffer: CVPixelBuffer) {
        context.render(image, to: buffer, bounds: image.extent, colorSpace: colorSpace)
    }
}

/// All methods (except PreviewFeed) execute on CaptureEngine.frameQueue.
final class FrameProcessor {
    let motion: MotionService
    let renderer: ImageRenderer
    let tracker = SubjectTracker()
    let preview = PreviewFeed()
    var settings = CameraSettings()
    var front = false
    private var horizon = HorizonEstimator()
    private var lastAngle = 0.0
    private var manualCenter = Point2(0.5, 0.5)
    private var pendingPinch: (target: Point2, anchor: Point2)?
    private var pendingTarget: Point2?
    private(set) var lastPlan: CropPlan?
    private var fpsStart = 0.0
    private var fpsCount = 0
    private var fps = 0.0
    var dropped = 0
    init(motion: MotionService, renderer: ImageRenderer) { self.motion = motion; self.renderer = renderer }
    func resetGeometry() {
        horizon.reset(); tracker.reset(); manualCenter = Point2(0.5, 0.5)
        pendingPinch = nil; pendingTarget = nil; lastPlan = nil; lastAngle = 0
        preview.publish(nil); fpsCount = 0; fpsStart = 0
    }
    func configure(_ next: CameraSettings, front: Bool) {
        if self.front != front || settings.framing != next.framing || settings.mirrorSelfie != next.mirrorSelfie {
            resetGeometry()
        }
        if settings.zoomLock != next.zoomLock { tracker.reset(); pendingTarget = nil }
        self.settings = next; self.front = front
    }
    /// UIKit tap normalized to TOP-left, converted exactly through the saved render transform.
    func selectTarget(atUIKit point: Point2) { pendingTarget = Point2(point.x, 1-point.y) }
    func setZoom(_ zoom: Double, atUIKit point: Point2?) {
        if let point, let plan = lastPlan, !settings.zoomLock {
            let anchor = Point2(point.x, 1-point.y)
            let source = plan.outputToSource(Point2(anchor.x*plan.output.width, anchor.y*plan.output.height))
            pendingPinch = (Point2(source.x/plan.source.width, source.y/plan.source.height), anchor)
        }
        settings.zoom = min(max(zoom, 1), 12)
    }
    func normalizedDevicePoint(atUIKit point: Point2) -> CGPoint? {
        guard let p = lastPlan else { return nil }
        let s = p.outputToSource(Point2(point.x*p.output.width, (1-point.y)*p.output.height))
        var x = CropGeometry.clamp(s.x/p.source.width, 0, 1)
        let y = CropGeometry.clamp(s.y/p.source.height, 0, 1)
        if front && settings.mirrorSelfie { x = 1-x }
        return CGPoint(x: 1-y, y: 1-x)
    }
    func process(buffer: CVPixelBuffer, hostTime: Double) throws -> PreviewFrame {
        var source = CIImage(cvPixelBuffer: buffer)
        if front && settings.mirrorSelfie { source = source.oriented(.upMirrored) }
        source = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        let size = Size2(source.extent.width, source.extent.height)
        var diagnostics = FrameDiagnostics()
        let reading = motion.sample(at: hostTime + settings.motionOffsetMilliseconds/1000)
        if let reading {
            let solution = horizon.update(reading, unmirroredFront: front && !settings.mirrorSelfie)
            lastAngle = solution.angle
            diagnostics.motionStatus = solution.gravityReliable ? "Horizon locked" : "Vertical view — gyro hold"
        } else {
            diagnostics.motionStatus = motion.available ? "Motion stale — holding angle" : "Motion unavailable"
        }
        let angle: Double
        if settings.horizonLock {
            angle = lastAngle + settings.horizonTrimDegrees * .pi/180
        } else {
            // Without Horizon Lock, orientation is a fixed framing choice, never
            // continuously counter-rotated. Portrait=0; landscape picks its side.
            if settings.framing == .landscape {
                angle = (reading?.gx ?? 1) >= 0 ? -.pi/2 : .pi/2
            } else { angle = 0 }
            diagnostics.motionStatus = "Horizon off"
        }
        var plan = try CropGeometry.plan(source: size, output: settings.outputSize, angle: angle,
            zoom: settings.zoom, fullTurn: settings.horizonLock, reserve: settings.reserve,
            requestedCenter: Point2(manualCenter.x*size.width, manualCenter.y*size.height))
        if let pinch = pendingPinch {
            let c = plan.centerHolding(target: Point2(pinch.target.x*size.width, pinch.target.y*size.height), at: pinch.anchor)
            manualCenter = Point2(c.x/size.width, c.y/size.height); pendingPinch = nil
        }
        if let target = pendingTarget {
            if settings.zoomLock {
                let p = (lastPlan ?? plan).outputToSource(Point2(target.x*plan.output.width, target.y*plan.output.height))
                let w = max(0.035, min(0.20, 0.14*plan.sourceDetail.width/size.width))
                let h = max(0.035, min(0.20, 0.14*plan.sourceDetail.height/size.height))
                tracker.seed(normalizedBox: CGRect(x: p.x/size.width-w/2, y: p.y/size.height-h/2, width: w, height: h), anchor: target)
            }
            pendingTarget = nil
        }
        if settings.zoomLock { tracker.update(image: source, time: hostTime) }
        var desired = Point2(manualCenter.x*size.width, manualCenter.y*size.height)
        if settings.zoomLock, let target = tracker.target {
            desired = plan.centerHolding(target: Point2(target.x*size.width, target.y*size.height), at: tracker.anchor)
        }
        plan = try CropGeometry.plan(source: size, output: settings.outputSize, angle: angle,
            zoom: settings.zoom, fullTurn: settings.horizonLock, reserve: settings.reserve, requestedCenter: desired)
        manualCenter = Point2(plan.center.x/size.width, plan.center.y/size.height)
        lastPlan = plan
        let output = renderer.filter(renderer.transform(source, plan: plan), settings.filter)
        let target = settings.zoomLock ? tracker.box.map { box -> Point2 in
            let p = plan.sourceToOutput(Point2(box.midX*size.width, box.midY*size.height))
            return Point2(p.x/plan.output.width, p.y/plan.output.height)
        } : nil
        fpsCount += 1
        if fpsStart == 0 { fpsStart = hostTime }
        if hostTime-fpsStart >= 1 { fps = Double(fpsCount)/(hostTime-fpsStart); fpsStart = hostTime; fpsCount = 0 }
        diagnostics.rollDegrees = lastAngle * 180 / .pi
        diagnostics.trackingStatus = settings.zoomLock ? (plan.wasClamped && tracker.state == .locked ? "Edge — move camera toward subject" : tracker.state.rawValue) : "Off"
        diagnostics.confidence = tracker.confidence; diagnostics.edgeLimited = plan.wasClamped
        diagnostics.detail = plan.sourceDetail; diagnostics.upscaled = plan.upscales
        diagnostics.deliveredFPS = fps; diagnostics.droppedFrames = dropped
        let frame = PreviewFrame(image: output, overview: source, plan: plan, target: target,
            trackingGood: tracker.state == .locked && !plan.wasClamped, diagnostics: diagnostics)
        preview.publish(frame)
        return frame
    }
    /// Native photos can contain more vertical FOV than the video stream. First
    /// normalize their center crop to the preview's source aspect, then reuse
    /// the exact normalized crop center and lock transform at still exposure time.
    func processPhoto(_ input: CIImage, hostTime: Double) throws -> CIImage {
        guard let live = lastPlan else { throw CameraFailure.message("The camera is not ready for a photo yet.") }
        var image = input
        if front && settings.mirrorSelfie { image = image.oriented(.upMirrored) }
        let e = image.extent, ratio = live.source.width/live.source.height
        let cropW = min(e.width, e.height*ratio), cropH = min(e.height, e.width/ratio)
        image = image.cropped(to: CGRect(x: e.midX-cropW/2,y: e.midY-cropH/2,width: cropW,height: cropH))
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,y: -image.extent.minY))
        let size = Size2(image.extent.width,image.extent.height)
        var angle = live.angle
        if settings.horizonLock, let m = motion.sample(at: hostTime+settings.motionOffsetMilliseconds/1000) {
            var estimator = horizon
            angle = estimator.update(m, unmirroredFront: front && !settings.mirrorSelfie).angle + settings.horizonTrimDegrees * .pi/180
        }
        // Never advertise a full-resolution locked still by merely upscaling it.
        let maxEdge = max(2, Int(max(live.sourceDetail.width,live.sourceDetail.height)*size.width/live.source.width))
        let out = settings.framing.size(longEdge: maxEdge)
        let p = try CropGeometry.plan(source:size, output:out, angle:angle,zoom:settings.zoom,
            fullTurn:settings.horizonLock,reserve:settings.reserve,
            requestedCenter:Point2(live.center.x/live.source.width*size.width,live.center.y/live.source.height*size.height))
        return renderer.filter(renderer.transform(image,plan:p),settings.filter)
    }
}
