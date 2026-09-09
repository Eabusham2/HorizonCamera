import Foundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers

enum CaptureMetadata {
    static func photo(_ settings: CameraSettings) -> [String: Any] {
        var tiff: [String: Any] = [kCGImagePropertyTIFFSoftware as String: "HorizonCamera"]
        if !settings.metadataAuthor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { tiff[kCGImagePropertyTIFFArtist as String] = settings.metadataAuthor }
        if !settings.metadataCopyright.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { tiff[kCGImagePropertyTIFFCopyright as String] = settings.metadataCopyright }
        let description = settings.metadataDescription.isEmpty ? settings.metadataTitle : settings.metadataDescription
        if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { tiff[kCGImagePropertyTIFFImageDescription as String] = description }
        var iptc: [String: Any] = [:]
        if !settings.metadataTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { iptc[kCGImagePropertyIPTCObjectName as String] = settings.metadataTitle }
        if !settings.metadataAuthor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { iptc[kCGImagePropertyIPTCByline as String] = settings.metadataAuthor }
        if !settings.metadataCopyright.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { iptc[kCGImagePropertyIPTCCopyrightNotice as String] = settings.metadataCopyright }
        if !settings.metadataDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { iptc[kCGImagePropertyIPTCCaptionAbstract as String] = settings.metadataDescription }
        let keywords = settings.metadataKeywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !keywords.isEmpty { iptc[kCGImagePropertyIPTCKeywords as String] = keywords }
        var metadata: [String: Any] = [kCGImagePropertyTIFFDictionary as String: tiff]
        if !iptc.isEmpty { metadata[kCGImagePropertyIPTCDictionary as String] = iptc }
        return metadata
    }

    static func encodeProcessed(_ image: CIImage, renderer: ImageRenderer, efficient: Bool, settings: CameraSettings) -> (Data, String)? {
        guard let cg = renderer.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: renderer.colorSpace) else { return nil }
        let data = NSMutableData()
        let type = efficient ? UTType.heic.identifier : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cg, photo(settings) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data, efficient ? "heic" : "jpg")
    }
}
