import XCTest
import AVFoundation
import ImageIO
import CoreLocation
@testable import HorizonCamera

final class AdvancedCameraTests: XCTestCase {
    func testNativeMovieModesDisableCustomPixelTransforms() {
        var s = CameraSettings()
        let old = s
        s.horizonLock = true; s.zoomLock = true; s.filter = .vivid; s.mode = .cinematic
        s.normalize(changedFrom: old)
        XCTAssertFalse(s.horizonLock); XCTAssertFalse(s.zoomLock); XCTAssertEqual(s.filter, .original)
        XCTAssertTrue(s.usesNativeMoviePipeline)
    }
    func testProResAndLogForceNativePipeline() {
        var s = CameraSettings(); let old = s
        s.codec = .proRes422; s.colorProfile = .appleLog
        s.normalize(changedFrom: old)
        XCTAssertTrue(s.usesNativeMoviePipeline)
        XCTAssertFalse(s.horizonLock)
    }
    func testExpandedResolutionAndFrameRateModel() {
        XCTAssertEqual(Resolution.hd.longEdge, 1280)
        var s = CameraSettings(); s.mode = .slowMotion; s.slowMotionFPS = 240; s.resolution = .hd
        XCTAssertEqual(s.captureFPS, 240)
        XCTAssertEqual(s.outputSize.width.rounded(), 720)
        XCTAssertEqual(s.outputSize.height.rounded(), 1280)
    }
    func testPhotoNativeExtrasRemainMutuallyExclusive() {
        var s = CameraSettings(); s.mode = .photo; s.horizonLock = false
        let old = s; s.raw = true; s.livePhoto = true; s.normalize(changedFrom: old)
        XCTAssertTrue(s.raw); XCTAssertFalse(s.livePhoto)
    }
    func testMetadataFieldsRoundTripThroughSettingsCodable() throws {
        var s = CameraSettings(); s.metadataAuthor = "Author"; s.metadataCopyright = "Copyright"; s.metadataDescription = "Description"
        let decoded = try JSONDecoder().decode(CameraSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded, s)
    }
    func testPortraitModeForcesNativeDepthSafeSettings() {
        var s = CameraSettings(); let old = s
        s.mode = .portrait; s.horizonLock = true; s.zoomLock = true; s.raw = true; s.livePhoto = true; s.filter = .vivid
        s.normalize(changedFrom: old)
        XCTAssertTrue(s.mode.isPhotoMode); XCTAssertFalse(s.mode.isMovie)
        XCTAssertTrue(s.depthData); XCTAssertTrue(s.portraitEffectsMatte)
        XCTAssertFalse(s.horizonLock); XCTAssertFalse(s.zoomLock); XCTAssertFalse(s.raw); XCTAssertFalse(s.livePhoto)
        XCTAssertEqual(s.filter,.original); XCTAssertEqual(s.photoFraming,.classic)
    }
    func testConstantColorForcesCompatibleFlashAndDisablesRawLive() {
        var s = CameraSettings(); s.mode = .photo; s.horizonLock = false
        let old = s; s.constantColor = true; s.raw = true; s.livePhoto = true; s.flash = .off
        s.normalize(changedFrom: old)
        XCTAssertTrue(s.constantColor); XCTAssertFalse(s.raw); XCTAssertFalse(s.livePhoto); XCTAssertEqual(s.flash,.auto)
    }
    func testNativeMovieFramingUsesRepresentableOrientation() {
        var s = CameraSettings(); let old = s
        s.mode = .cinematic; s.videoFraming = .square
        s.normalize(changedFrom: old)
        XCTAssertEqual(s.videoFraming,.portrait)
    }
    func testPhotoMetadataContainsStandardTIFFAndIPTCFields() throws {
        var s = CameraSettings(); s.metadataTitle = "Title"; s.metadataAuthor = "Eyad"; s.metadataCopyright = "Copyright"; s.metadataDescription = "Description"; s.metadataKeywords = "camera, horizon"
        let metadata = CaptureMetadata.photo(s)
        let tiff = try XCTUnwrap(metadata[kCGImagePropertyTIFFDictionary as String] as? [String:Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFArtist as String] as? String,"Eyad")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFSoftware as String] as? String,"HorizonCamera")
        let iptc = try XCTUnwrap(metadata[kCGImagePropertyIPTCDictionary as String] as? [String:Any])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCObjectName as String] as? String,"Title")
        XCTAssertEqual((iptc[kCGImagePropertyIPTCKeywords as String] as? [String]) ?? [],["camera","horizon"])
    }

    func testSourceExifSurvivesCustomMetadataMerge() throws {
        var settings = CameraSettings(); settings.metadataAuthor = "New Author"
        let originalExif: [String:Any] = [kCGImagePropertyExifExposureTime as String: 0.01]
        let metadata = CaptureMetadata.photo(settings,base:[kCGImagePropertyExifDictionary as String:originalExif])
        let exif = try XCTUnwrap(metadata[kCGImagePropertyExifDictionary as String] as? [String:Any])
        XCTAssertEqual(exif[kCGImagePropertyExifExposureTime as String] as? Double,0.01)
    }
    func testISO6709AndGPSMetadataFormatting() {
        let location = CLLocation(coordinate:CLLocationCoordinate2D(latitude:30.2672,longitude:-97.7431),altitude:155,
            horizontalAccuracy:6,verticalAccuracy:8,timestamp:Date())
        let iso = CaptureLocation.iso6709(location)
        XCTAssertTrue(iso.hasPrefix("+30.267200-97.743100+155.0"))
        let gps = CaptureLocation.gpsDictionary(location)
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef as String] as? String,"N")
        XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef as String] as? String,"W")
    }
    func testNativeMovieMetadataIncludesEditableFields() {
        var settings = CameraSettings(); settings.metadataTitle = "Test Title"; settings.metadataAuthor = "Test Author"; settings.metadataKeywords = "one,two"
        let metadata = NativeMovieController.movieMetadata(settings)
        XCTAssertTrue(metadata.contains { $0.identifier == .quickTimeMetadataTitle && $0.stringValue == "Test Title" })
        XCTAssertTrue(metadata.contains { $0.identifier == .quickTimeMetadataAuthor && $0.stringValue == "Test Author" })
        XCTAssertTrue(metadata.contains { $0.identifier == .quickTimeMetadataSoftware })
    }

    func testOldSettingsJSONMigratesWithoutLosingExistingValues() throws {
        let old = """{"mode":"VIDEO","zoom":2.5,"grid":false,"horizonLock":false}""".data(using:.utf8)!
        let migrated = try XCTUnwrap(CameraModel.decodeSettingsMigrating(old))
        XCTAssertEqual(migrated.mode,.video); XCTAssertEqual(migrated.zoom,2.5); XCTAssertFalse(migrated.grid); XCTAssertFalse(migrated.horizonLock)
        XCTAssertTrue(migrated.scanQRCodes); XCTAssertTrue(migrated.showDetectedText); XCTAssertTrue(migrated.lensCleaningHints)
    }
    func testNewDetectionAndSwitchingSettingsRoundTrip() throws {
        var settings = CameraSettings(); settings.lockCameraSwitching = true; settings.centerStage = true; settings.smartFraming = true
        settings.photoResolutionMP = 24; settings.scanQRCodes = false; settings.showDetectedText = false; settings.lensCleaningHints = false
        let decoded = try JSONDecoder().decode(CameraSettings.self,from:JSONEncoder().encode(settings))
        XCTAssertEqual(decoded,settings)
    }

}
