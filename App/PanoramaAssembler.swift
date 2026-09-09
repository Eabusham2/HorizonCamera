import CoreImage
import Foundation

final class PanoramaAssembler {
    private struct Frame { let yaw: Double; let image: CIImage }
    private let renderer: ImageRenderer
    private let horizontalFOV: Double
    private let feather: Double
    private var frames: [Frame] = []
    private var lastYaw: Double?
    private var lastStoredYaw: Double?
    private let maxFrames = 72

    init(renderer: ImageRenderer, horizontalFOVDegrees: Double, feather: Double) {
        self.renderer = renderer
        self.horizontalFOV = max(20,min(140,horizontalFOVDegrees)) * .pi / 180
        self.feather = min(max(feather,0.1),0.9)
    }

    var count: Int { frames.count }

    func append(_ input: CIImage, yaw rawYaw: Double) {
        let yaw = lastYaw.map { AngleMath.unwrap(rawYaw,near:$0) } ?? rawYaw
        lastYaw = yaw
        if let stored = lastStoredYaw, abs(yaw-stored) < 3.5 * .pi / 180 { return }
        guard frames.count < maxFrames else { return }
        var image = input.transformed(by:CGAffineTransform(translationX:-input.extent.minX,y:-input.extent.minY))
        let maxHeight: CGFloat = 1080
        if image.extent.height > maxHeight {
            let scale = maxHeight / image.extent.height
            image = image.applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:scale,kCIInputAspectRatioKey:1.0])
        }
        guard let cg = renderer.context.createCGImage(image,from:image.extent,format:.RGBA8,colorSpace:renderer.colorSpace) else { return }
        frames.append(Frame(yaw:yaw,image:CIImage(cgImage:cg)))
        lastStoredYaw = yaw
    }

    func finish() throws -> CIImage {
        guard frames.count >= 2 else { throw CameraFailure.message("Panorama needs more sweep frames. Move the iPhone sideways, then stop again.") }
        let sorted = frames.sorted { $0.yaw < $1.yaw }
        let h = sorted.map { $0.image.extent.height }.min() ?? 0
        guard h > 1 else { throw CameraFailure.message("Panorama frames were invalid.") }
        let normalized: [(Double,CIImage)] = sorted.map { item in
            var image = item.image
            if abs(image.extent.height-h) > 0.5 {
                let scale = h/image.extent.height
                image = image.applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:scale,kCIInputAspectRatioKey:1.0])
            }
            image = image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
            return (item.yaw,image)
        }
        let frameWidth = normalized[0].1.extent.width
        let pixelsPerRadian = frameWidth / CGFloat(horizontalFOV)
        let minYaw = normalized.first!.0
        let positions = normalized.map { CGFloat($0.0-minYaw) * pixelsPerRadian }
        let width = (zip(positions,normalized).map { $0.0 + $0.1.1.extent.width }.max() ?? frameWidth).rounded(.up)
        let canvasRect = CGRect(x:0,y:0,width:max(frameWidth,width),height:h)
        var canvas = CIImage(color:.clear).cropped(to:canvasRect)
        var previousRight: CGFloat = 0
        for (index,item) in normalized.enumerated() {
            let x = positions[index]
            let frame = item.1.transformed(by:CGAffineTransform(translationX:x,y:0)).cropped(to:canvasRect)
            if index == 0 {
                canvas = frame.applyingFilter("CISourceOverCompositing",parameters:[kCIInputBackgroundImageKey:canvas]).cropped(to:canvasRect)
            } else {
                let overlap = max(1,previousRight-x)
                let featherWidth = max(1,overlap * CGFloat(feather))
                let p0 = CIVector(x:x,y:0), p1 = CIVector(x:min(x+overlap,x+featherWidth),y:0)
                let mask = CIFilter(name:"CILinearGradient",parameters:["inputPoint0":p0,"inputPoint1":p1,"inputColor0":CIColor(red:0,green:0,blue:0,alpha:0),"inputColor1":CIColor(red:1,green:1,blue:1,alpha:1)])!.outputImage!.cropped(to:canvasRect)
                let transparent = CIImage(color:.clear).cropped(to:canvasRect)
                let masked = frame.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:transparent,kCIInputMaskImageKey:mask])
                canvas = masked.applyingFilter("CISourceOverCompositing",parameters:[kCIInputBackgroundImageKey:canvas]).cropped(to:canvasRect)
            }
            previousRight = max(previousRight,x+item.1.extent.width)
        }
        return canvas.cropped(to:canvasRect)
    }
}
