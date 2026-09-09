import Foundation
import ImageIO
import CoreImage
import AVFoundation
import UniformTypeIdentifiers

enum CaptureMetadata {
    static func photo(_ settings: CameraSettings, base: [String: Any] = [:]) -> [String: Any] {
        var metadata = base
        if settings.customMetadataEnabled {
            var tiff: [String: Any] = (metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
            tiff[kCGImagePropertyTIFFSoftware as String] = "HorizonCamera"
            if !settings.metadataAuthor.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { tiff[kCGImagePropertyTIFFArtist as String]=settings.metadataAuthor }
            if !settings.metadataCopyright.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { tiff[kCGImagePropertyTIFFCopyright as String]=settings.metadataCopyright }
            let description=settings.metadataDescription.isEmpty ? settings.metadataTitle : settings.metadataDescription
            if !description.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { tiff[kCGImagePropertyTIFFImageDescription as String]=description }
            if !tiff.isEmpty { metadata[kCGImagePropertyTIFFDictionary as String]=tiff }
            var iptc:[String:Any]=(metadata[kCGImagePropertyIPTCDictionary as String] as? [String:Any]) ?? [:]
            if !settings.metadataTitle.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { iptc[kCGImagePropertyIPTCObjectName as String]=settings.metadataTitle }
            if !settings.metadataAuthor.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { iptc[kCGImagePropertyIPTCByline as String]=settings.metadataAuthor }
            if !settings.metadataCopyright.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { iptc[kCGImagePropertyIPTCCopyrightNotice as String]=settings.metadataCopyright }
            if !settings.metadataDescription.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { iptc[kCGImagePropertyIPTCCaptionAbstract as String]=settings.metadataDescription }
            let keywords=settings.metadataKeywords.split(separator:",").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}
            if !keywords.isEmpty { iptc[kCGImagePropertyIPTCKeywords as String]=keywords }
            if !iptc.isEmpty { metadata[kCGImagePropertyIPTCDictionary as String]=iptc }
        }
        if settings.includeLocationMetadata, let location=CaptureLocation.shared.current() {
            metadata[kCGImagePropertyGPSDictionary as String]=CaptureLocation.gpsDictionary(location)
        }
        if !base.isEmpty {
            metadata[kCGImagePropertyOrientation as String]=1
            metadata.removeValue(forKey:kCGImagePropertyPixelWidth as String)
            metadata.removeValue(forKey:kCGImagePropertyPixelHeight as String)
        }
        return metadata
    }

    static func encodeProcessed(_ image: CIImage, renderer: ImageRenderer, efficient: Bool, settings: CameraSettings, sourceData: Data? = nil,
                                depthData: AVDepthData? = nil, portraitEffectsMatte: AVPortraitEffectsMatte? = nil) -> (Data, String)? {
        guard let cg = renderer.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: renderer.colorSpace) else { return nil }
        let data = NSMutableData()
        let type = efficient ? UTType.heic.identifier : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        var base: [String:Any] = [:]
        if let sourceData, let source = CGImageSourceCreateWithData(sourceData as CFData,nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any] { base = properties }
        let properties=photo(settings,base:base)
        if !properties.isEmpty { CGImageDestinationSetProperties(destination,properties as CFDictionary) }
        let encodeOptions:[String:Any]=[kCGImageDestinationLossyCompressionQuality as String:efficient ? 0.98 : 0.96]
        CGImageDestinationAddImage(destination,cg,encodeOptions as CFDictionary)
        if let depthData {
            var type: NSString?
            if let dictionary = depthData.dictionaryRepresentation(forAuxiliaryDataType:&type), let type {
                CGImageDestinationAddAuxiliaryDataInfo(destination,type as CFString,dictionary as CFDictionary)
            }
        }
        if let portraitEffectsMatte {
            var type: NSString?
            if let dictionary = portraitEffectsMatte.dictionaryRepresentation(forAuxiliaryDataType:&type), let type {
                CGImageDestinationAddAuxiliaryDataInfo(destination,type as CFString,dictionary as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data, efficient ? "heic" : "jpg")
    }
}
