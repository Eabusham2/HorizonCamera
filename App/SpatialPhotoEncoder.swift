import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

@available(iOS 18.0, *)
enum SpatialPhotoEncoder {
    static func encode(left:CGImage,right:CGImage,commonFOV:Double,rightPosition:[Double],rightRotation:[Double],settings:CameraSettings) throws -> Data {
        guard left.width == right.width,left.height == right.height else { throw CameraFailure.message("Spatial Photo eye images must have identical pixel dimensions.") }
        let data=NSMutableData(), destinationProperties:[CFString:Any]=[kCGImagePropertyPrimaryImage:0]
        guard let destination=CGImageDestinationCreateWithData(data,UTType.heic.identifier as CFString,2,destinationProperties as CFDictionary) else { throw CameraFailure.message("Could not create the spatial HEIC destination.") }
        let identity:[Double]=[1,0,0,0,1,0,0,0,1]
        CGImageDestinationAddImage(destination,left,properties(isLeft:true,image:left,fov:commonFOV,position:[0,0,0],rotation:identity,settings:settings) as CFDictionary)
        CGImageDestinationAddImage(destination,right,properties(isLeft:false,image:right,fov:commonFOV,position:rightPosition,rotation:rightRotation,settings:settings) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CameraFailure.message("Image I/O could not finalize the spatial HEIC.") }
        return data as Data
    }

    static func properties(isLeft:Bool,image:CGImage,fov:Double,position:[Double],rotation:[Double],settings:CameraSettings) -> [CFString:Any] {
        let w=Double(image.width),h=Double(image.height),radians=max(1,min(179,fov)) * .pi/180
        let focal=(w*0.5)/tan(radians*0.5),intrinsics:[Double]=[focal,0,w*0.5,0,focal,h*0.5,0,0,1]
        var props:[CFString:Any]=[
            kCGImagePropertyGroups:[kCGImagePropertyGroupIndex:0,kCGImagePropertyGroupType:kCGImagePropertyGroupTypeStereoPair,
                (isLeft ? kCGImagePropertyGroupImageIsLeftImage:kCGImagePropertyGroupImageIsRightImage):true,
                kCGImagePropertyGroupImageDisparityAdjustment:0],
            kCGImagePropertyHEIFDictionary:[kIIOMetadata_CameraExtrinsicsKey:[kIIOCameraExtrinsics_Position:position,kIIOCameraExtrinsics_Rotation:rotation],
                kIIOMetadata_CameraModelKey:[kIIOCameraModel_Intrinsics:intrinsics,kIIOCameraModel_ModelType:kIIOCameraModelType_SimplifiedPinhole]],
            kCGImagePropertyHasAlpha:false]
        for (key,value) in CaptureMetadata.photo(settings) { props[key as CFString]=value }
        return props
    }
}
