import Foundation
import CoreImage
import Metal
import CoreVideo

struct PreviewFrame {
    let image: CIImage
    let recordingImage: CIImage
    let overview: CIImage
    let plan: CropPlan
    let recordingPlan: CropPlan
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
    let videoColorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
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
        // Extend edge texels only for the resampling filter footprint. Geometry
        // still constrains the entire output to the real sensor image.
        return image.clampedToExtent().transformed(by: transform).cropped(to: CGRect(x: 0, y: 0,
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

    func photographicStyle(_ image: CIImage, settings: CameraSettings) -> CIImage {
        var styled = image
        switch settings.photographicStyle {
        case .standard: break
        case .vibrant:
            styled = styled.applyingFilter("CIVibrance", parameters:[kCIInputAmountKey:0.55])
                .applyingFilter("CIColorControls", parameters:[kCIInputSaturationKey:1.08,kCIInputContrastKey:1.04])
        case .richContrast:
            styled = styled.applyingFilter("CIHighlightShadowAdjust", parameters:["inputHighlightAmount":0.72,"inputShadowAmount":-0.18])
                .applyingFilter("CIColorControls", parameters:[kCIInputContrastKey:1.14,kCIInputSaturationKey:1.02])
        case .warm:
            styled = styled.applyingFilter("CITemperatureAndTint", parameters:["inputNeutral":CIVector(x:6500,y:0),"inputTargetNeutral":CIVector(x:7350,y:0)])
        case .cool:
            styled = styled.applyingFilter("CITemperatureAndTint", parameters:["inputNeutral":CIVector(x:6500,y:0),"inputTargetNeutral":CIVector(x:5650,y:0)])
        case .roseGold:
            styled = styled.applyingFilter("CIColorMatrix", parameters:[
                "inputRVector":CIVector(x:1.05,y:0.02,z:0,w:0),
                "inputGVector":CIVector(x:0.02,y:1.00,z:0.01,w:0),
                "inputBVector":CIVector(x:0.03,y:0.01,z:0.94,w:0)])
                .applyingFilter("CIVibrance", parameters:[kCIInputAmountKey:0.2])
        case .muted:
            styled = styled.applyingFilter("CIColorControls", parameters:[kCIInputSaturationKey:0.78,kCIInputContrastKey:0.96])
                .applyingFilter("CIHighlightShadowAdjust", parameters:["inputHighlightAmount":0.9,"inputShadowAmount":0.15])
        }
        if abs(settings.styleTone) > 0.001 {
            styled = styled.applyingFilter("CIExposureAdjust", parameters:[kCIInputEVKey: settings.styleTone * 0.45])
                .applyingFilter("CIColorControls", parameters:[kCIInputContrastKey:1 + settings.styleTone * 0.06])
        }
        if abs(settings.styleWarmth) > 0.001 {
            let kelvin = 6500 + settings.styleWarmth * 1400
            styled = styled.applyingFilter("CITemperatureAndTint", parameters:["inputNeutral":CIVector(x:6500,y:0),"inputTargetNeutral":CIVector(x:kelvin,y:0)])
        }
        let amount = min(max(settings.styleIntensity,0),1)
        if amount >= 0.999 { return styled }
        if amount <= 0.001 { return image }
        return image.applyingFilter("CIDissolveTransition", parameters:[kCIInputTargetImageKey:styled,kCIInputTimeKey:amount])
    }

    func applyLook(_ image: CIImage, settings: CameraSettings) -> CIImage {
        filter(photographicStyle(image, settings:settings), settings.filter)
    }

    func fuseBracket(_ images: [CIImage], mode: ComputationalPhotoMode) -> CIImage? {
        guard !images.isEmpty else { return nil }
        let biases = mode.exposureBiases
        let extent = images.dropFirst().reduce(images[0].extent) { $0.intersection($1.extent) }
        guard !extent.isNull, extent.width > 1, extent.height > 1 else { return nil }
        var normalized: [CIImage] = []
        for (index,image) in images.enumerated() {
            var frame = image.cropped(to:extent)
            if index < biases.count, abs(biases[index]) > 0.001 {
                frame = frame.applyingFilter("CIExposureAdjust", parameters:[kCIInputEVKey:-biases[index]])
            }
            normalized.append(frame)
        }
        var combined = normalized[0]
        for frame in normalized.dropFirst() {
            combined = frame.applyingFilter("CIAdditionCompositing", parameters:[kCIInputBackgroundImageKey:combined])
        }
        let scale = CGFloat(1.0 / Double(normalized.count))
        combined = combined.applyingFilter("CIColorMatrix", parameters:[
            "inputRVector":CIVector(x:scale,y:0,z:0,w:0),
            "inputGVector":CIVector(x:0,y:scale,z:0,w:0),
            "inputBVector":CIVector(x:0,y:0,z:scale,w:0),
            "inputAVector":CIVector(x:0,y:0,z:0,w:1)])
        switch mode {
        case .off: return combined
        case .autoHDR:
            return combined.applyingFilter("CIHighlightShadowAdjust", parameters:["inputHighlightAmount":0.62,"inputShadowAmount":0.32])
                .applyingFilter("CIUnsharpMask", parameters:[kCIInputRadiusKey:2.2,kCIInputIntensityKey:0.22])
        case .night:
            return combined.applyingFilter("CINoiseReduction", parameters:["inputNoiseLevel":0.035,"inputSharpness":0.42])
                .applyingFilter("CIHighlightShadowAdjust", parameters:["inputHighlightAmount":0.72,"inputShadowAmount":0.48])
                .applyingFilter("CIExposureAdjust", parameters:[kCIInputEVKey:0.28])
        case .detailFusion:
            return combined.applyingFilter("CINoiseReduction", parameters:["inputNoiseLevel":0.018,"inputSharpness":0.55])
                .applyingFilter("CISharpenLuminance", parameters:[kCIInputSharpnessKey:0.42])
                .applyingFilter("CIUnsharpMask", parameters:[kCIInputRadiusKey:1.6,kCIInputIntensityKey:0.20])
        }
    }

    func portraitLighting(_ image: CIImage, matte: CIImage?, style: PortraitLightingApprox, blurRadius: Double) -> CIImage {
        guard let matte else { return style == .natural ? image : photographicFallback(image,style:style) }
        let sx = image.extent.width / max(1,matte.extent.width), sy = image.extent.height / max(1,matte.extent.height)
        var mask = matte.transformed(by:CGAffineTransform(scaleX:sx,y:sy))
        mask = mask.transformed(by:CGAffineTransform(translationX:image.extent.minX-mask.extent.minX,y:image.extent.minY-mask.extent.minY))
            .cropped(to:image.extent)
            .applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:1.4]).cropped(to:image.extent)
        let blurred = image.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:max(0,blurRadius)]).cropped(to:image.extent)
        let black = CIImage(color:.black).cropped(to:image.extent)
        let white = CIImage(color:.white).cropped(to:image.extent)
        let subject: CIImage
        let background: CIImage
        switch style {
        case .natural:
            subject = image; background = blurred
        case .studio:
            subject = image.applyingFilter("CIColorControls",parameters:[kCIInputBrightnessKey:0.08,kCIInputContrastKey:0.96,kCIInputSaturationKey:1.02]); background = blurred
        case .contour:
            subject = image.applyingFilter("CIColorControls",parameters:[kCIInputContrastKey:1.24,kCIInputSaturationKey:0.95])
                .applyingFilter("CIVignette",parameters:[kCIInputIntensityKey:0.35,kCIInputRadiusKey:1.2]); background = blurred
        case .stage:
            subject = image.applyingFilter("CIColorControls",parameters:[kCIInputBrightnessKey:0.04,kCIInputContrastKey:1.10]); background = black
        case .stageMono:
            subject = image.applyingFilter("CIPhotoEffectNoir"); background = black
        case .highKeyMono:
            subject = image.applyingFilter("CIPhotoEffectMono").applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:0.25]); background = white
        }
        return subject.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:background,kCIInputMaskImageKey:mask])
    }

    private func photographicFallback(_ image: CIImage, style: PortraitLightingApprox) -> CIImage {
        switch style {
        case .natural: return image
        case .studio: return image.applyingFilter("CIColorControls",parameters:[kCIInputBrightnessKey:0.08,kCIInputContrastKey:0.98])
        case .contour: return image.applyingFilter("CIColorControls",parameters:[kCIInputContrastKey:1.22])
        case .stage: return image.applyingFilter("CIVignetteEffect",parameters:[kCIInputIntensityKey:0.85,kCIInputRadiusKey:0.7])
        case .stageMono: return image.applyingFilter("CIPhotoEffectNoir").applyingFilter("CIVignetteEffect",parameters:[kCIInputIntensityKey:0.9,kCIInputRadiusKey:0.7])
        case .highKeyMono: return image.applyingFilter("CIPhotoEffectMono").applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:0.35])
        }
    }
    func render(_ image: CIImage, into buffer: CVPixelBuffer) {
        context.render(image, to: buffer, bounds: image.extent, colorSpace: colorSpace)
    }
    func renderVideo(_ image: CIImage, into buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
        CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
        CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
        context.render(image,to:buffer,bounds:image.extent,colorSpace:videoColorSpace)
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
    private var zoomAnchor: (target: Point2, anchor: Point2)?
    private var renderedZoom = 1.0
    private var zoomTimestamp: Double?
    private var actionOffset = Point2(0,0)
    private var actionTimestamp: Double?
    private var frameLockOffset = Point2(0,0)
    private var frameLockTimestamp: Double?
    private var horizontalFOVDegrees = 70.0
    private var pendingTarget: Point2?
    private(set) var lastPlan: CropPlan?
    private var frozenAngle: Double?
    private var planHistory: [(Double, CropPlan)] = []
    private var fpsStart = 0.0
    private var fpsCount = 0
    private var fps = 0.0
    var dropped = 0
    init(motion: MotionService, renderer: ImageRenderer) { self.motion = motion; self.renderer = renderer }
    func resetGeometry() {
        horizon.reset(); tracker.reset(); manualCenter = Point2(0.5, 0.5)
        zoomAnchor = nil; zoomTimestamp = nil; actionOffset = Point2(0,0); actionTimestamp = nil; frameLockOffset = Point2(0,0); frameLockTimestamp = nil; pendingTarget = nil; lastPlan = nil; lastAngle = 0
        renderedZoom = settings.zoom
        preview.publish(nil); fpsCount = 0; fpsStart = 0; planHistory.removeAll(); frozenAngle = nil
    }
    func beginRecording() { frozenAngle = lastPlan?.angle }
    func endRecording() { frozenAngle = nil }
    func configure(_ next: CameraSettings, front: Bool, horizontalFOVDegrees: Double? = nil) {
        let geometryReset = self.front != front || settings.framing != next.framing || settings.mirrorSelfie != next.mirrorSelfie
        if geometryReset { resetGeometry() }
        if settings.zoomLock != next.zoomLock { tracker.reset(); pendingTarget = nil; zoomAnchor = nil; frameLockOffset = .zero; frameLockTimestamp = nil }
        if settings.actionStabilization != next.actionStabilization { actionOffset = Point2(0,0); actionTimestamp = nil }
        self.settings = next; self.front = front
        if let horizontalFOVDegrees, horizontalFOVDegrees.isFinite, horizontalFOVDegrees > 1 { self.horizontalFOVDegrees = horizontalFOVDegrees }
        if geometryReset { renderedZoom = next.zoom; zoomTimestamp = nil }
    }
    /// UIKit tap normalized to TOP-left, converted exactly through the saved render transform.
    func selectTarget(atUIKit point: Point2) { pendingTarget = Point2(point.x, 1-point.y) }
    func setZoom(_ zoom: Double, atUIKit point: Point2?) {
        if let point, let plan = lastPlan, !settings.zoomLock {
            let anchor = Point2(point.x, 1-point.y)
            let source = plan.outputToSource(Point2(anchor.x*plan.output.width, anchor.y*plan.output.height))
            zoomAnchor = (Point2(source.x/plan.source.width, source.y/plan.source.height), anchor)
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

        // Zoom Lock is a floating sensor crop, not a subject-only tracker. Integrate
        // camera pitch/yaw so the selected framing stays fixed until the real sensor
        // boundary is reached. CropGeometry clamps at the edge; we then saturate the
        // integrator there so reversing direction immediately gives travel back.
        if settings.zoomLock, let reading {
            let dt = min(0.05, max(0, hostTime - (frameLockTimestamp ?? hostTime)))
            let delta = FrameLockMath.delta(rateX: reading.rateX, rateY: reading.rateY, dt: dt,
                                            horizontalFOVDegrees: horizontalFOVDegrees,
                                            sourceAspect: size.width / max(1, size.height))
            frameLockOffset = frameLockOffset + delta
            frameLockTimestamp = hostTime
        } else if !settings.zoomLock {
            frameLockOffset = .zero; frameLockTimestamp = hostTime
        }

        // Action uses the same immediate timestamp-aligned gyro data but is kept out
        // of the preview. It only affects the recording image below, like Apple's
        // stock Camera preview/output split.
        if settings.actionStabilization, let reading {
            let dt = min(0.05,max(0,hostTime-(actionTimestamp ?? hostTime)))
            let gain = 0.12 + 0.24 * settings.actionStrength
            let decay = exp(-1.7 * dt)
            actionOffset = Point2(actionOffset.x*decay - reading.rateY*dt*gain,
                                  actionOffset.y*decay + reading.rateX*dt*gain)
            actionOffset.x = CropGeometry.clamp(actionOffset.x,-0.18,0.18)
            actionOffset.y = CropGeometry.clamp(actionOffset.y,-0.18,0.18)
            actionTimestamp = hostTime
        } else { actionOffset = Point2(0,0); actionTimestamp = hostTime }

        let previewAngle: Double
        if settings.horizonLock {
            previewAngle = lastAngle + settings.horizonTrimDegrees * .pi/180
        } else if settings.framing == .landscape {
            previewAngle = frozenAngle ?? ((reading?.gx ?? 1) >= 0 ? -.pi/2 : .pi/2)
        } else { previewAngle = 0; diagnostics.motionStatus = "Horizon off" }

        if let previous = zoomTimestamp {
            renderedZoom = ZoomTransition.step(current:renderedZoom,target:settings.zoom,deltaTime:max(0,hostTime-previous))
        } else { renderedZoom = settings.zoom }
        zoomTimestamp = hostTime

        var previewPlan = try CropGeometry.plan(source:size, output:settings.outputSize, angle:previewAngle,
            zoom:renderedZoom, fullTurn:settings.horizonLock, reserve:settings.previewReserve,
            requestedCenter:Point2((manualCenter.x+frameLockOffset.x)*size.width,
                                   (manualCenter.y+frameLockOffset.y)*size.height))

        if let pinch = zoomAnchor, !settings.zoomLock {
            let c = previewPlan.centerHolding(target:Point2(pinch.target.x*size.width,pinch.target.y*size.height),at:pinch.anchor)
            manualCenter = Point2(c.x/size.width,c.y/size.height)
            if abs(log2(renderedZoom/settings.zoom)) < 0.002 { zoomAnchor=nil }
            previewPlan = try CropGeometry.plan(source:size,output:settings.outputSize,angle:previewAngle,
                zoom:renderedZoom,fullTurn:settings.horizonLock,reserve:settings.previewReserve,
                requestedCenter:Point2(manualCenter.x*size.width,manualCenter.y*size.height))
        }

        if let target=pendingTarget {
            if settings.zoomLock {
                let p=(lastPlan ?? previewPlan).outputToSource(Point2(target.x*previewPlan.output.width,target.y*previewPlan.output.height))
                manualCenter=Point2(p.x/size.width,p.y/size.height)
                frameLockOffset = .zero
                frameLockTimestamp=hostTime
                tracker.reset()
                previewPlan=try CropGeometry.plan(source:size,output:settings.outputSize,angle:previewAngle,
                    zoom:renderedZoom,fullTurn:settings.horizonLock,reserve:settings.previewReserve,
                    requestedCenter:Point2(manualCenter.x*size.width,manualCenter.y*size.height))
            }
            pendingTarget=nil
        }

        if settings.zoomLock && previewPlan.wasClamped {
            frameLockOffset = Point2(previewPlan.center.x/size.width-manualCenter.x,
                                     previewPlan.center.y/size.height-manualCenter.y)
        } else if !settings.zoomLock {
            manualCenter = Point2(previewPlan.center.x/size.width,previewPlan.center.y/size.height)
        }

        // Recording/output plan can be more aggressive than preview. Horizon and
        // Zoom Lock remain WYSIWYG; Action and Smart Artifact Guard add output-only
        // motion/crop headroom so the viewfinder stays responsive and uncluttered.
        var captureAngle = previewAngle
        if settings.actionStabilization && !settings.horizonLock {
            captureAngle = lastAngle * (0.45 + 0.45*settings.actionStrength)
        }
        let captureCenter = Point2(previewPlan.center.x + actionOffset.x*size.width,
                                   previewPlan.center.y + actionOffset.y*size.height)
        let capturePlan = try CropGeometry.plan(source:size, output:settings.outputSize, angle:captureAngle,
            zoom:renderedZoom, fullTurn:settings.horizonLock, reserve:settings.captureReserve,
            requestedCenter:captureCenter)

        lastPlan = previewPlan
        planHistory.append((hostTime,capturePlan))
        if planHistory.count > 600 { planHistory.removeFirst(planHistory.count-600) }

        let previewImage = renderer.applyLook(renderer.transform(source,plan:previewPlan),settings:settings)
        let recordingImage = renderer.applyLook(renderer.transform(source,plan:capturePlan),settings:settings)
        let target = settings.zoomLock ? Point2(0.5,0.5) : nil
        fpsCount += 1
        if fpsStart == 0 { fpsStart=hostTime }
        if hostTime-fpsStart >= 1 { fps=Double(fpsCount)/(hostTime-fpsStart); fpsStart=hostTime; fpsCount=0 }
        diagnostics.rollDegrees=lastAngle*180/.pi
        diagnostics.trackingStatus = settings.zoomLock ? (previewPlan.wasClamped ? "Edge" : "Locked") : "Off"
        diagnostics.confidence=0; diagnostics.edgeLimited=previewPlan.wasClamped
        diagnostics.detail=capturePlan.sourceDetail; diagnostics.upscaled=capturePlan.upscales
        diagnostics.deliveredFPS=fps; diagnostics.droppedFrames=dropped
        let frame=PreviewFrame(image:previewImage,recordingImage:recordingImage,overview:source,plan:previewPlan,recordingPlan:capturePlan,target:target,
            trackingGood:settings.zoomLock && !previewPlan.wasClamped,diagnostics:diagnostics)
        preview.publish(frame)
        return frame
    }
    /// Native photos can contain more vertical FOV than the video stream. First
    /// normalize their center crop to the preview's source aspect, then reuse
    /// the exact normalized crop center and lock transform at still exposure time.
    func processPhoto(_ input: CIImage, hostTime: Double) throws -> CIImage {
        guard let live = planHistory.min(by: { abs($0.0-hostTime) < abs($1.0-hostTime) })?.1 ?? lastPlan else { throw CameraFailure.message("The camera is not ready for a photo yet.") }
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
        let p = try CropGeometry.plan(source:size, output:out, angle:angle,zoom:live.zoom,
            fullTurn:settings.horizonLock,reserve:settings.reserve,
            requestedCenter:Point2(live.center.x/live.source.width*size.width,live.center.y/live.source.height*size.height))
        return renderer.applyLook(renderer.transform(image,plan:p),settings:settings)
    }
}
